#!/bin/sh
set -eu
wake_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
runtime=${1:-"$wake_dir/.build/current"}
app=${CODEX_WAKE_APP:-/Applications/ChatGPT.app}
node=$(command -v node || true)
if [ -z "$node" ]; then
    printf '%s\n' 'Install Node.js and make node available in PATH before launching Desktop.' >&2
    exit 1
fi
if [ ! -x "$runtime/codex" ]; then
    printf 'Build the runtime with %s/build.sh first.\n' "$wake_dir" >&2
    exit 1
fi
runtime=$(CDPATH= cd -- "$runtime" && pwd)
app_cli="$app/Contents/Resources/codex-cli/bin/codex"
if [ ! -x "$app_cli" ]; then
    printf 'ChatGPT Desktop was not found at %s.\n' "$app" >&2
    exit 1
fi
bundled_version=$("$app_cli" --version)
runtime_version=$(cat "$runtime/version")
if [ "$bundled_version" != "$runtime_version" ]; then
    printf 'Desktop bundles %s. This archive requires %s.\n' "$bundled_version" "$runtime_version" >&2
    printf '%s\n' 'Use ./codex in the terminal, or build a matching runtime for Desktop.' >&2
    exit 1
fi
if /usr/bin/pgrep -x ChatGPT >/dev/null; then
    printf '%s\n' 'Quit ChatGPT Desktop before starting it with this runtime.' >&2
    exit 1
fi

session=$(mktemp -d /tmp/cxwake.XXXXXX)
cleanup() {
    rm -rf -- "$session"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
desktop_executable=$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$app/Contents/Info.plist")
CODEX_CLI_PATH="$wake_dir/codex" \
CODEX_APP_SERVER_FORCE_CLI=1 \
CODEX_WAKE_BINARY="$runtime/codex" \
CODEX_WAKE_NODE="$node" \
CODEX_WAKE_SOCKET="$session" \
"$node" "$wake_dir/desktop-driver.mjs" "$app/Contents/MacOS/$desktop_executable" "$session"
