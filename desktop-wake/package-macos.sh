#!/bin/sh
set -eu

if [ "$#" -ne 3 ]; then
    printf 'Usage: %s RUNTIME_DIR SIDECAR_DIR OUTPUT_DIR\n' "$0" >&2
    exit 2
fi

wake_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(dirname -- "$wake_dir")
runtime_dir=$1
sidecar_dir=$2
output_dir=$3
arch=$(lipo -archs "$runtime_dir/codex")
case "$arch" in
    arm64|x86_64) ;;
    *) printf 'Expected a single macOS architecture, got %s.\n' "$arch" >&2; exit 1 ;;
esac

archive_name=codex-wake-macos-$arch
scratch=$(mktemp -d "${TMPDIR:-/tmp}/codex-wake-package.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
package_dir="$scratch/$archive_name"
mkdir -p "$package_dir/desktop-wake" "$output_dir"

install -m 755 "$runtime_dir/codex" "$package_dir/codex"
install -m 755 "$runtime_dir/BackgroundMenu" "$package_dir/BackgroundMenu"
for helper in codex-exec-server codex-code-mode-host; do
    install -m 755 "$sidecar_dir/$helper" "$package_dir/$helper"
    if ! codesign --verify "$package_dir/$helper" 2>/dev/null; then
        codesign --force --sign - "$package_dir/$helper"
    fi
done
for executable in BackgroundMenu codex-exec-server codex-code-mode-host; do
    test "$(lipo -archs "$package_dir/$executable")" = "$arch"
    codesign --verify "$package_dir/$executable"
done

install -m 755 "$wake_dir/launch.sh" "$package_dir/desktop-wake/launch.sh"
install -m 755 "$wake_dir/codex" "$package_dir/desktop-wake/codex"
install -m 644 "$wake_dir/bridge.mjs" "$package_dir/desktop-wake/bridge.mjs"
install -m 644 "$repo_dir/LICENSE" "$repo_dir/NOTICE" "$package_dir/"
install -m 644 "$wake_dir/README.md" "$package_dir/README.md"
install -m 644 "$runtime_dir/version" "$package_dir/version"

cat > "$package_dir/launch-desktop.command" <<'EOF'
#!/bin/sh
set -eu
release_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec "$release_dir/desktop-wake/launch.sh" "$release_dir"
EOF
chmod 755 "$package_dir/launch-desktop.command"

# Stripping modifies the Mach-O, so sign the packaged copy again.
strip -x "$package_dir/codex"
codesign --force --sign - "$package_dir/codex"
codesign --verify "$package_dir/codex"
test "$("$package_dir/codex" --version)" = "$(cat "$package_dir/version")"

archive="$output_dir/$archive_name.tar.gz"
COPYFILE_DISABLE=1 tar -czf "$archive" -C "$scratch" "$archive_name"
(cd "$output_dir" && shasum -a 256 "$archive_name.tar.gz" > "$archive_name.tar.gz.sha256")
printf '%s\n' "$archive"
