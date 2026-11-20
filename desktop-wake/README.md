# Codex Wake for macOS

This local fork uses the open-source Codex runtime bundled with ChatGPT Desktop. The launcher selects the patched runtime with `CODEX_CLI_PATH`. A macOS menu bar control lists commands started by the connected app and lets you hand off a live command. The installed app bundle and global launcher settings are untouched.

- **Move to background** releases the current shell wait and ends foreground model work at its next tool boundary. The original process keeps running. The completion event delivers its exit code and bounded output to the same thread.
- In Desktop, the latest response footer shows the running Wake command count for the open chat. Click the count to see the commands and their elapsed times.
- When a long shell command blocks the next step, Codex starts it, reports that it is still running, and parks the chat with `on_exit: "wake"` on the existing session. The result wakes the same chat so Codex can continue the original task.
- A child agent waits for its own command inside its runtime until the result arrives. It remains running from its parent's point of view. With the upstream `wake_on_agent_messages` feature enabled, an idle root thread resumes when agent mail arrives. The standard `wait_agent` retains its upstream timeout behavior.
- Jobs belong to the running Codex process. Quitting the app ends that runtime and its jobs. The menu handles agent shell calls that use Unified Exec. The separate interactive Desktop terminal uses its own shell session.

## Open Codex Wake.app

Download `codex-wake-macos-arm64-app.zip` from [GitHub Releases](https://github.com/SuLG-ik/codex-wake/releases) on an Apple Silicon Mac. Extract the ZIP and open **Codex Wake.app** in Finder. It starts the installed ChatGPT Desktop app with the patched runtime and adds the background command menu to the macOS menu bar. The launcher offers to quit ChatGPT first if it is already open.

This app build pairs with ChatGPT Desktop that bundles `codex-cli 0.171.0-alpha.13`. The app checks the bundled version before it opens Desktop. Node.js and the runtime helpers are included. The release uses ad-hoc signing and includes a SHA-256 checksum.

The patched terminal CLI is also available inside the app at `Codex Wake.app/Contents/Resources/runtime/codex`.

## Build and launch from source

Run on the Mac with Xcode command-line tools, Node.js and the version of Rust in `codex-rs/rust-toolchain.toml`. The checkout's runtime version must match Desktop's bundled runtime. The first build downloads Cargo and V8 dependencies.

```sh
./desktop-wake/build.sh
./desktop-wake/launch.sh
```

Run the launcher after quitting existing ChatGPT windows and the app itself. The terminal that launched it stays open while the app runs. Launching ChatGPT normally uses its official runtime.

An external Codex runtime can affect signature-dependent features such as Computer Use or browser integration. See [openai/codex#34583](https://github.com/openai/codex/issues/34583).

To create the Finder app release, run `./desktop-wake/package-macos.sh RUNTIME_DIR SIDECAR_DIR OUTPUT_DIR NODE_DIST_DIR`. Verify the asset digests and extract the matching `codex-exec-server` and `codex-code-mode-host` binaries from the [official CLI release](https://github.com/openai/codex/releases/tag/rust-v0.171.0-alpha.13) into `SIDECAR_DIR`. Use an extracted [official Node.js distribution](https://nodejs.org/dist/) with `bin/node` and `LICENSE` for `NODE_DIST_DIR`. Omitting that last argument builds the terminal archive.

## Updates

Keep the patch commits above the matching upstream tag. After Desktop updates, run `./desktop-wake/prepare-update.sh` from a clean checkout. It reads the bundled CLI version, fetches that exact upstream tag, and replays the patches into a separate worktree. It regenerates workspace version entries in the Cargo lock when an upstream release tag still uses `0.0.0` there. Conflicts stop that worktree's update.

Regenerate the experimental RPC export and commit the export separately in the candidate checkout. The build checks the bundled version and runs the bridge test. Before switching, verify the Rust integration tests for a manually detached command and a model-started background command, then use a disposable Desktop chat to test the menu, an exit with a nonzero status, a new prompt during a background job, and a child agent waiting for its own job. Every candidate has its own runtime directory. When the patched runtime for the currently installed Desktop version is unavailable, launch the official Desktop normally.

```sh
cd codex-rs
python3 app-server-protocol/scripts/write_schema_fixtures.py --experimental
cargo test --locked -p codex-app-server-protocol --lib experimental_precomputed_exports_match_generated
cargo test --locked -p codex-app-server --test all background_command_resumes_idle_thread
```
