#!/bin/sh
set -eu

if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
    printf 'Usage: %s RUNTIME_DIR SIDECAR_DIR OUTPUT_DIR [NODE_DIST_DIR]\n' "$0" >&2
    exit 2
fi

wake_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(dirname -- "$wake_dir")
runtime_dir=$1
sidecar_dir=$2
output_dir=$3
node_dist=${4:-}
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
for script in bridge.mjs desktop-driver.mjs thread-background-ui.js; do
    install -m 644 "$wake_dir/$script" "$package_dir/desktop-wake/$script"
done
install -m 644 "$repo_dir/LICENSE" "$repo_dir/NOTICE" "$package_dir/"
install -m 644 "$wake_dir/README.md" "$package_dir/README.md"
install -m 644 "$runtime_dir/version" "$package_dir/version"

# Stripping modifies the Mach-O, so sign the packaged copy again.
strip -x "$package_dir/codex"
codesign --force --sign - "$package_dir/codex"
codesign --verify "$package_dir/codex"
test "$("$package_dir/codex" --version)" = "$(cat "$package_dir/version")"

if [ -n "$node_dist" ]; then
    app_dir="$scratch/Codex Wake.app"
    resources="$app_dir/Contents/Resources"
    mkdir -p "$app_dir/Contents/MacOS" "$resources/node/bin"
    mv "$package_dir" "$resources/runtime"
    install -m 755 "$node_dist/bin/node" "$resources/node/bin/node"
    install -m 644 "$node_dist/LICENSE" "$resources/node/LICENSE"
    test "$(lipo -archs "$resources/node/bin/node")" = "$arch"
    if ! codesign --verify "$resources/node/bin/node" 2>/dev/null; then
        codesign --force --sign - "$resources/node/bin/node"
    fi

    cp "$wake_dir/DesktopApp.swift" "$scratch/DesktopApp.swift"
    xcrun swiftc -target "$arch-apple-macosx13.0" -module-cache-path "$scratch/swift-cache" \
        "$scratch/DesktopApp.swift" -o "$app_dir/Contents/MacOS/CodexWake"
    cat > "$app_dir/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleDisplayName</key><string>Codex Wake</string>
    <key>CFBundleExecutable</key><string>CodexWake</string>
    <key>CFBundleIdentifier</key><string>com.sulg-ik.codex-wake</string>
    <key>CFBundleName</key><string>Codex Wake</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.4.0</string>
    <key>CFBundleVersion</key><string>4</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict></plist>
EOF
    plutil -lint "$app_dir/Contents/Info.plist"
    codesign --force --sign - "$app_dir"
    codesign --verify --deep "$app_dir"
    archive_file="$archive_name-app.zip"
    ditto -c -k --sequesterRsrc --keepParent "$app_dir" "$output_dir/$archive_file"
else
    cat > "$package_dir/launch-desktop.command" <<'EOF'
#!/bin/sh
set -eu
release_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec "$release_dir/desktop-wake/launch.sh" "$release_dir"
EOF
    chmod 755 "$package_dir/launch-desktop.command"
    archive_file="$archive_name.tar.gz"
    COPYFILE_DISABLE=1 tar -czf "$output_dir/$archive_file" -C "$scratch" "$archive_name"
fi
(cd "$output_dir" && shasum -a 256 "$archive_file" > "$archive_file.sha256")
printf '%s\n' "$output_dir/$archive_file"
