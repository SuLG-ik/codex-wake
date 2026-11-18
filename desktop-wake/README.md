# Codex Wake for macOS

This local fork uses the open-source Codex runtime bundled with ChatGPT Desktop. The launcher selects the patched runtime with `CODEX_CLI_PATH`. A macOS menu bar control lists commands started by the connected app and lets you hand off a live command. The installed app bundle and global launcher settings are untouched.

- **Move to background** releases the current shell wait and ends foreground model work at its next tool boundary. The original process keeps running. The completion event delivers its exit code and bounded output to the same thread.
- Codex can pass `on_exit: "wake"` to `exec_command` or to an empty `write_stdin` call for an existing process. The tool descriptions explain when to use it.
- A child agent waits for its own command inside its runtime until the result arrives. It remains running from its parent's point of view. `wait_agent(until_event: true)` waits on agent events instead of looping on a timeout. In Multi-Agent V2, a root thread becomes idle and resumes on agent mail. In V1 the tool waits for a selected child's final status in the current turn.
- Jobs belong to the running Codex process. Quitting the app ends that runtime and its jobs. The menu handles agent shell calls that use Unified Exec. The separate interactive Desktop terminal uses its own shell session.

## Run the release

Download `codex-wake-macos-arm64.tar.gz` from [GitHub Releases](https://github.com/SuLG-ik/codex-wake/releases) on an Apple Silicon Mac. The release also provides a SHA-256 checksum. Extract the archive and open a terminal in the extracted `codex-wake-macos-arm64` directory.

```sh
./codex --version
./codex
```

Sign in on that Mac when prompted. The terminal build includes its runtime helpers and works independently of the installed Desktop version.

For the Desktop menu, install Node.js and use a ChatGPT Desktop build with bundled `codex-cli 0.169.0-alpha.11.1`. Quit ChatGPT Desktop, then run `./launch-desktop.command`. The patched runtime and its Desktop bridge were tested together with local mock-model workflows. A full launch in the Desktop GUI remains unverified.

## Build and launch from source

Run on the Mac with Xcode command-line tools, Node.js and the version of Rust in `codex-rs/rust-toolchain.toml`. The checkout's runtime version must match Desktop's bundled runtime. The first build downloads Cargo and V8 dependencies.

```sh
./desktop-wake/build.sh
./desktop-wake/launch.sh
```

Run the launcher after quitting existing ChatGPT windows and the app itself. The terminal that launched it stays open while the app runs. Launching ChatGPT normally uses its official runtime.

An external Codex runtime can affect signature-dependent features such as Computer Use or browser integration. See [openai/codex#34583](https://github.com/openai/codex/issues/34583).

To create a portable release archive, run `./desktop-wake/package-macos.sh RUNTIME_DIR SIDECAR_DIR OUTPUT_DIR`. Use the matching `codex-exec-server` and `codex-code-mode-host` binaries from the [official CLI release](https://github.com/openai/codex/releases/tag/rust-v0.169.0-alpha.11.1) in `SIDECAR_DIR`.

## Updates

Keep the patch commits above the matching upstream tag. After Desktop updates, run `./desktop-wake/prepare-update.sh` from a clean checkout. It reads the bundled CLI version, fetches that exact upstream tag, and replays the patches into a separate worktree. It regenerates workspace version entries in the Cargo lock when an upstream release tag still uses `0.0.0` there. Conflicts stop that worktree's update.

Regenerate the experimental RPC export and commit the export separately in the candidate checkout. The build checks the bundled version and runs the bridge test. Before switching, verify the Rust integration tests for a manually detached command and a model-started background command, then use a disposable Desktop chat to test the menu, an exit with a nonzero status, a new prompt during a background job, and a child agent waiting for its own job. Every candidate has its own runtime directory. When the patched runtime for the currently installed Desktop version is unavailable, launch the official Desktop normally.

```sh
cd codex-rs
python3 app-server-protocol/scripts/write_schema_fixtures.py --experimental
cargo test --locked -p codex-app-server-protocol --lib experimental_precomputed_exports_match_generated
cargo test --locked -p codex-app-server --test all background_command_resumes_idle_thread
```
