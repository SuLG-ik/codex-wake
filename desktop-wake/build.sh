#!/bin/sh
set -eu
wake_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(dirname -- "$wake_dir")
runtime=${1:-"$wake_dir/.build/current"}
app=${CODEX_WAKE_APP:-/Applications/ChatGPT.app}
bundle="$app/Contents/Resources/codex-cli"
profile=${CODEX_WAKE_BUILD_PROFILE:-dev-small}
candidate=$(mktemp -d "${TMPDIR:-/tmp}/codex-wake-candidate.XXXXXX")
trap 'rm -rf "$candidate"' EXIT HUP INT TERM

app_version=$("$bundle/bin/codex" --version)
source_version=$(sed -n '/^\[workspace.package\]/{n;s/^version = "\([^"]*\)".*/codex-cli \1/p;}' "$repo_dir/codex-rs/Cargo.toml")
if [ "$source_version" != "$app_version" ]; then
    printf '%s\n' "Desktop provides $app_version. The checkout contains $source_version." >&2
    exit 1
fi

export CARGO_INCREMENTAL=0
export CARGO_TARGET_DIR=${CODEX_WAKE_TARGET_DIR:-"$wake_dir/.build/target"}
(cd "$repo_dir/codex-rs" && cargo build --locked --profile "$profile" -p codex-cli --bin codex)
install -m 755 "$CARGO_TARGET_DIR/$profile/codex" "$candidate/codex"
for sidecar in codex-exec-server codex-code-mode-host; do
    install -m 755 "$bundle/bin/$sidecar" "$candidate/$sidecar"
done
node --test "$wake_dir/bridge.test.mjs"
test "$("$candidate/codex" --version)" = "$app_version"
printf '%s\n' "$app_version" > "$candidate/version"

mkdir -p "$(dirname -- "$runtime")"
if [ -e "$runtime" ]; then
    printf 'Runtime already exists at %s. Build into a fresh path.\n' "$runtime" >&2
    exit 1
fi
mv "$candidate" "$runtime"
trap - EXIT HUP INT TERM
printf 'Built %s\n' "$runtime"
