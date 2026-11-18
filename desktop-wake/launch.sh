#!/bin/sh
set -eu
wake_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
runtime=${1:-"$wake_dir/.build/current"}
app=${CODEX_WAKE_APP:-/Applications/ChatGPT.app}
node=$(command -v node)
if [ ! -x "$runtime/codex" ] || [ ! -x "$runtime/BackgroundMenu" ]; then
    printf 'Build the runtime with %s/build.sh first.\n' "$wake_dir" >&2
    exit 1
fi
runtime=$(CDPATH= cd -- "$runtime" && pwd)
if [ "$("$app/Contents/Resources/codex-cli/bin/codex" --version)" != "$(cat "$runtime/version")" ]; then
    printf '%s\n' 'Build against the CLI version bundled with the updated Desktop app first.' >&2
    exit 1
fi
if /usr/bin/pgrep -x ChatGPT >/dev/null; then
    printf '%s\n' 'Quit ChatGPT Desktop before starting it with this runtime.' >&2
    exit 1
fi

session=$(mktemp -d /tmp/cxwake.XXXXXX)
menu_pid=
cleanup() {
    if [ -n "$menu_pid" ]; then kill "$menu_pid" 2>/dev/null || true; fi
    rm -f "$session"/rpc-*
    rmdir "$session"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
"$runtime/BackgroundMenu" "$node" "$wake_dir/bridge.mjs" "$session" "$$" &
menu_pid=$!
/usr/bin/open -W -a "$app" \
    --env "CODEX_CLI_PATH=$wake_dir/codex" \
    --env "CODEX_WAKE_BINARY=$runtime/codex" \
    --env "CODEX_WAKE_NODE=$node" \
    --env "CODEX_WAKE_SOCKET=$session"
