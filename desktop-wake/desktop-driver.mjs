import { spawn } from "node:child_process";
import { open, readFile, readdir, stat, unlink } from "node:fs/promises";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

export class DesktopPipe {
  #nextId = 0;
  #requests = new Map();
  #buffer = "";
  #closed = false;

  constructor(input, output) {
    this.input = input;
    output.setEncoding("utf8");
    output.on("data", (chunk) => {
      this.#buffer += chunk;
      let delimiter;
      while ((delimiter = this.#buffer.indexOf("\0")) !== -1) {
        const message = JSON.parse(this.#buffer.slice(0, delimiter));
        this.#buffer = this.#buffer.slice(delimiter + 1);
        const pending = this.#requests.get(message.id);
        if (!pending) continue;
        this.#requests.delete(message.id);
        if (message.error) pending.reject(new Error(message.error.message));
        else pending.resolve(message.result);
      }
    });
    const close = () => {
      this.#closed = true;
      for (const pending of this.#requests.values()) pending.reject(new Error("Desktop pipe closed"));
      this.#requests.clear();
    };
    output.on("end", close);
    output.on("error", close);
    input.on("error", close);
  }

  call(method, params = {}, sessionId) {
    if (this.#closed) return Promise.reject(new Error("Desktop pipe closed"));
    const id = ++this.#nextId;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.#requests.delete(id);
        reject(new Error(`Desktop did not answer ${method}`));
      }, 3000);
      this.#requests.set(id, {
        resolve: (value) => { clearTimeout(timer); resolve(value); },
        reject: (error) => { clearTimeout(timer); reject(error); },
      });
      this.input.write(JSON.stringify({ id, method, params, sessionId }) + "\0");
    });
  }
}

const threadIdPattern = /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i;
const taskFilePattern = /^wake-task-([1-9]\d{0,9})-[0-9a-f-]{36}\.json$/;

export async function readWakeTasks(directory) {
  const tasks = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const match = taskFilePattern.exec(entry.name);
    if (!match || !entry.isFile()) continue;
    try {
      const pid = Number(match[1]);
      process.kill(pid, 0);
      const task = JSON.parse(await readFile(join(directory, entry.name), "utf8"));
      if (task.serverPid !== pid || !Number.isFinite(task.startedAtMs) ||
          typeof task.command !== "string" || !threadIdPattern.test(task.threadId)) continue;
      tasks.push({ id: entry.name, threadId: task.threadId.toLowerCase(),
        command: task.command, startedAtMs: task.startedAtMs });
    } catch (error) {
      // Exit and publication can race with directory enumeration.
      if (!(error instanceof SyntaxError) && !["ENOENT", "ESRCH", "EPERM"].includes(error.code)) throw error;
    }
  }
  return tasks.sort((first, second) => first.startedAtMs - second.startedAtMs || first.id.localeCompare(second.id));
}

async function requestTaskStop(directory, id) {
  const taskPath = join(directory, id);
  const stopPath = taskPath + ".stop";
  try {
    await stat(taskPath);
    const marker = await open(stopPath, "wx", 0o600);
    await marker.close();
    // A naturally completed task may disappear while writing the stop marker.
    try {
      await stat(taskPath);
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
      await unlink(stopPath).catch((cleanupError) => {
        if (cleanupError.code !== "ENOENT") throw cleanupError;
      });
    }
  } catch (error) {
    if (!["EEXIST", "ENOENT"].includes(error.code)) throw error;
  }
}

function isDesktopPage(target) {
  if (target.type !== "page") return false;
  try {
    const url = new URL(target.url);
    return url.protocol === "app:" && url.hostname === "-";
  } catch {
    return false;
  }
}

export function launchDesktop(executable, args = [], options = {}) {
  return spawn(executable, ["--remote-debugging-pipe", ...args], {
    ...options,
    stdio: ["ignore", "ignore", "inherit", "pipe", "pipe"],
  });
}

export class WakeDesktopUi {
  #windows = new Map();

  constructor(pipe, renderer, directory) {
    this.pipe = pipe;
    this.renderer = renderer;
    this.directory = directory;
  }

  async #evaluate(window, expression) {
    const response = await this.pipe.call("Runtime.evaluate", {
      contextId: window.contextId, expression, returnByValue: true,
    }, window.sessionId);
    if (response.exceptionDetails) throw new Error("Wake renderer evaluation failed");
    return response.result?.value;
  }

  async #ensureContext(window) {
    if (window.contextId) return;
    const { frameTree } = await this.pipe.call("Page.getFrameTree", {}, window.sessionId);
    const { executionContextId } = await this.pipe.call("Page.createIsolatedWorld", {
      frameId: frameTree.frame.id, worldName: "codex-wake-background",
    }, window.sessionId);
    window.contextId = executionContextId;
    await this.#evaluate(window, this.renderer);
  }

  async sync() {
    const [{ targetInfos }, tasks] = await Promise.all([
      this.pipe.call("Target.getTargets"), readWakeTasks(this.directory),
    ]);
    const pages = targetInfos.filter(isDesktopPage);
    const live = new Set(pages.map(({ targetId }) => targetId));
    for (const id of this.#windows.keys()) {
      if (!live.has(id)) this.#windows.delete(id);
    }

    for (const { targetId } of pages) {
      let window = this.#windows.get(targetId);
      try {
        if (!window) {
          const { sessionId } = await this.pipe.call("Target.attachToTarget", { targetId, flatten: true });
          window = { sessionId };
          this.#windows.set(targetId, window);
        }
        await this.#ensureContext(window);
        const { thread, requests } = await this.#evaluate(window, "globalThis.codexWakeBackground.readState()");
        for (const request of requests) {
          if (window.visibleTasks?.get(request.id) !== request.thread ||
              !tasks.some((task) => task.id === request.id && task.threadId === request.thread)) continue;
          try {
            await requestTaskStop(this.directory, request.id);
          } catch {
            await this.#evaluate(window, `globalThis.codexWakeBackground.stopFailed(${JSON.stringify(request.id)})`);
          }
        }
        if (thread !== null && !threadIdPattern.test(thread)) continue;
        const relevant = tasks.filter((task) => task.threadId === thread);
        const payload = JSON.stringify([thread, relevant]);
        if (window.snapshot !== payload) {
          await this.#evaluate(window, `globalThis.codexWakeBackground.setTasks(...${payload})`);
          window.snapshot = payload;
          window.visibleTasks = new Map(relevant.map((task) => [task.id, thread]));
        }
      } catch (error) {
        if (/session (?:with given id )?not found|target closed/i.test(error.message)) {
          this.#windows.delete(targetId);
        } else if (window) {
          // Reloads replace the isolated world but retain the target and session.
          window.contextId = null;
          window.snapshot = null;
          window.visibleTasks = null;
        }
      }
    }
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const [executable, directory] = process.argv.slice(2);
  const renderer = await readFile(new URL("./thread-background-ui.js", import.meta.url), "utf8");
  const child = launchDesktop(executable);
  const ui = new WakeDesktopUi(new DesktopPipe(child.stdio[3], child.stdio[4]), renderer, directory);
  let active = true;
  const finished = new Promise((resolve, reject) => {
    child.once("error", reject);
    child.once("exit", (code) => {
      active = false;
      resolve(code ?? 0);
    });
  });
  for (const sig of ["SIGTERM", "SIGINT"]) {
    process.once(sig, () => { if (active) child.kill(sig); });
  }
  async function refresh() {
    while (active) {
      try { await ui.sync(); } catch {
        // Desktop can take time to open a renderer or may be shutting down.
      }
      if (active) await new Promise((resolve) => setTimeout(resolve, 750));
    }
  }
  const refreshing = refresh();
  process.exitCode = await finished;
  await refreshing;
}
