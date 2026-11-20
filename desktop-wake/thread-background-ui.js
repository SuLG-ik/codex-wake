(() => {
  if (globalThis.codexWakeBackground) return;

  const idPattern = "[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}";
  const route = new RegExp(`^/local/(${idPattern})(?:[/?#]|$)`, "i");
  const stylesheet = new CSSStyleSheet();
  stylesheet.replaceSync(`
    .wake-inline-status { display: inline-flex; align-items: center; gap: .35rem;
      margin-inline-start: .3rem; color: var(--color-text-secondary, inherit);
      font: inherit; white-space: nowrap; }
    .wake-inline-status button { border: 0; background: transparent; color: inherit;
      cursor: pointer; font: inherit; padding: 0 2px; border-radius: 3px; }
    .wake-inline-status button:hover { text-decoration: underline; }
    .wake-inline-status button:focus-visible { outline: 2px solid currentColor; outline-offset: 2px; }
    #wake-background-popover { position: fixed; inset: auto; margin: 0; box-sizing: border-box;
      width: min(355px, calc(100vw - 16px)); max-height: min(320px, 85vh);
      overflow: auto; padding: 12px 14px; border-radius: 10px;
      border: 1px solid light-dark(#ddd, #454545); color: light-dark(#222, #eee);
      background: light-dark(#fff, #262626); color-scheme: light dark;
      box-shadow: 0 8px 28px #0004; font-family: system-ui, sans-serif; font-size: 13px; }
    #wake-background-popover h2 { font: inherit; font-weight: 600; margin: 0 0 8px; }
    #wake-background-popover ul { list-style: none; margin: 0; padding: 0; }
    #wake-background-popover li { display: grid; grid-template-columns: minmax(0, 1fr) auto;
      gap: 12px; padding: 8px 0; border-top: 1px solid light-dark(#eee, #3d3d3d); }
    #wake-background-popover code { overflow-wrap: anywhere; white-space: pre-wrap; }
    #wake-background-popover time { opacity: .75; white-space: nowrap; }
  `);
  document.adoptedStyleSheets = [...document.adoptedStyleSheets, stylesheet];

  const wrap = document.createElement("span");
  wrap.className = "wake-inline-status";
  const separator = document.createElement("span");
  separator.textContent = "·";
  separator.setAttribute("aria-hidden", "true");
  const trigger = document.createElement("button");
  trigger.type = "button";
  trigger.setAttribute("aria-controls", "wake-background-popover");
  trigger.setAttribute("aria-expanded", "false");
  wrap.append(separator, trigger);
  const fallback = document.createElement("div");
  fallback.style.paddingBlock = "4px";
  fallback.style.fontSize = "12px";

  const popup = document.createElement("section");
  popup.id = "wake-background-popover";
  popup.setAttribute("popover", "auto");
  popup.setAttribute("aria-labelledby", "wake-background-title");
  const title = document.createElement("h2");
  title.id = "wake-background-title";
  title.textContent = "Фоновые задачи";
  const list = document.createElement("ul");
  popup.append(title, list);

  const plural = new Intl.PluralRules("ru");
  let tasks = [];
  let displayedThread = null;
  let entries = new Map();
  let pendingLayout = false;

  const composerSelector = "[data-above-composer-conversation-id]";
  const activeThreadSelector = '[data-app-action-sidebar-thread-kind="local"][data-app-action-sidebar-thread-active="true"][data-app-action-sidebar-thread-id]';
  const threadKey = new RegExp(`(?:^|:)${idPattern}$`, "i");
  const attributes = ["data-above-composer-conversation-id", "data-app-action-sidebar-thread-active",
    "data-app-action-sidebar-thread-id", "inert", "hidden"];

  function threadFromKey(value) {
    if (!value || !threadKey.test(value)) return null;
    return value.slice(-36).toLowerCase();
  }

  function visibleComposers() {
    return [...document.querySelectorAll(composerSelector)].filter((element) =>
      !element.closest("[inert], [hidden]") && element.parentElement?.getClientRects().length,
    );
  }

  function currentThread() {
    const selected = document.querySelector(activeThreadSelector);
    const selectedThread = threadFromKey(selected?.getAttribute("data-app-action-sidebar-thread-id"));
    const composers = visibleComposers();
    if (selectedThread && (composers.length === 0 || composers.some((element) =>
      threadFromKey(element.getAttribute("data-above-composer-conversation-id")) === selectedThread,
    ))) return selectedThread;
    if (composers.length === 1 && !selectedThread) {
      return threadFromKey(composers[0].getAttribute("data-above-composer-conversation-id"));
    }
    const match = route.exec(location.pathname) || route.exec(location.hash.slice(1));
    return match ? match[1].toLowerCase() : null;
  }

  function mainTranscript() {
    return document.querySelector('[data-thread-find-target="conversation"]:not([data-rail-chat-transcript])');
  }

  function findTimestamp() {
    const composer = visibleComposers().find((element) =>
      threadFromKey(element.getAttribute("data-above-composer-conversation-id")) === displayedThread,
    );
    let scope = composer?.parentElement;
    while (scope && !scope.querySelector(".turn-action-controls")) scope = scope.parentElement;
    const rows = [...(mainTranscript() ?? scope ?? document).querySelectorAll(".turn-action-controls")].reverse();
    for (const row of rows) {
      if (!(row.classList.contains("min-h-5") || row.classList.contains("h-5"))) continue;
      if (!row.getClientRects().length) continue;
      const stamp = [...row.children].find((child) =>
        child.tagName === "SPAN" && child.classList.contains("ms-1.5") &&
        /\S/.test(child.textContent) && child !== wrap,
      );
      if (stamp) return stamp;
    }
    return null;
  }

  function positionPopup() {
    if (!popup.matches(":popover-open") || !wrap.isConnected) return;
    const anchor = trigger.getBoundingClientRect();
    const spacing = 8;
    const left = Math.max(spacing, Math.min(anchor.left, innerWidth - popup.offsetWidth - spacing));
    const top = anchor.bottom + popup.offsetHeight + spacing <= innerHeight
      ? anchor.bottom + spacing
      : Math.max(spacing, anchor.top - popup.offsetHeight - spacing);
    popup.style.left = `${left}px`;
    popup.style.top = `${top}px`;
  }

  function layout() {
    pendingLayout = false;
    const active = tasks.length > 0 && displayedThread === currentThread();
    const stamp = active ? findTimestamp() : null;
    const transcript = active && !stamp ? mainTranscript() : null;
    if (!stamp && !transcript) {
      if (popup.matches(":popover-open")) popup.hidePopover();
      wrap.remove();
      fallback.remove();
      return;
    }
    if (separator.hidden !== !stamp) separator.hidden = !stamp;
    if (stamp) {
      if (stamp.nextElementSibling !== wrap) {
        const style = getComputedStyle(stamp.firstElementChild ?? stamp);
        wrap.style.color = style.color;
        wrap.style.fontSize = style.fontSize;
        stamp.after(wrap);
      }
      fallback.remove();
    } else if (fallback.parentElement !== transcript || !fallback.contains(wrap)) {
      wrap.style.removeProperty("color");
      wrap.style.removeProperty("font-size");
      fallback.append(wrap);
      transcript.append(fallback);
    }
    if (!popup.isConnected) document.body.append(popup);
    positionPopup();
  }

  function scheduleLayout() {
    if (!pendingLayout && tasks.length > 0) {
      pendingLayout = true;
      queueMicrotask(layout);
    }
  }

  function updateElapsed() {
    for (const { task, time } of entries.values()) {
      const seconds = Math.max(0, Math.floor((Date.now() - task.startedAtMs) / 1000));
      const current = Math.floor(seconds / 60) + ":" + String(seconds % 60).padStart(2, "0");
      if (time.textContent !== current) time.textContent = current;
    }
  }

  function setTasks(thread, nextTasks) {
    if (thread !== currentThread()) return;
    if (thread !== displayedThread && popup.matches(":popover-open")) popup.hidePopover();
    displayedThread = thread;
    tasks = nextTasks;

    const count = tasks.length;
    const label = count === 1
      ? "Запущена 1 задача в фоне"
      : `Запущено ${count} ${plural.select(count) === "few" ? "задачи" : "задач"} в фоне`;
    if (trigger.textContent !== label) trigger.textContent = label;

    const nextEntries = new Map();
    for (const task of tasks) {
      let entry = entries.get(task.id);
      if (!entry) {
        const row = document.createElement("li");
        const command = document.createElement("code");
        command.textContent = task.command || "Команда";
        const time = document.createElement("time");
        row.append(command, time);
        entry = { row, task, time };
      }
      nextEntries.set(task.id, entry);
    }
    list.replaceChildren(...[...nextEntries.values()].map((entry) => entry.row));
    entries = nextEntries;
    updateElapsed();
    layout();
  }

  trigger.addEventListener("click", () => {
    popup.togglePopover();
    positionPopup();
  });
  popup.addEventListener("toggle", () => {
    trigger.setAttribute("aria-expanded", String(popup.matches(":popover-open")));
  });
  addEventListener("resize", scheduleLayout);
  addEventListener("scroll", positionPopup, true);
  new MutationObserver(scheduleLayout).observe(document.documentElement, {
    childList: true, subtree: true, attributes: true, attributeFilter: attributes,
  });
  setInterval(updateElapsed, 1000);

  globalThis.codexWakeBackground = Object.freeze({ currentThread, setTasks });
})();
