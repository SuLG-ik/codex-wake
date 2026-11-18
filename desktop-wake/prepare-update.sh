#!/bin/sh
set -eu
wake_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo=$(dirname -- "$wake_dir")
app=${CODEX_WAKE_APP:-/Applications/ChatGPT.app}
base=$(git -C "$repo" describe --tags --match 'rust-v*' --abbrev=0)
upstream_repo=${CODEX_WAKE_UPSTREAM:-https://github.com/openai/codex.git}
installed=$("$app/Contents/Resources/codex-cli/bin/codex" --version)
version=${installed#codex-cli }
tag=rust-v$version
destination=${1:-"$(dirname -- "$repo")/codex-wake-$version"}

if [ "$base" = "$tag" ]; then
    printf 'The checkout already uses Desktop runtime %s.\n' "$version"
    exit 0
fi
if [ -n "$(git -C "$repo" status --porcelain)" ]; then
    printf 'Commit the patch series before preparing an update.\n' >&2
    exit 1
fi

git -C "$repo" fetch --depth 1 "$upstream_repo" "refs/tags/$tag:refs/tags/$tag"
git -C "$repo" worktree add -b "wake-on-command-exit-$version" "$destination" "$tag"
git -C "$repo" rev-list --reverse "$base..HEAD" | while IFS= read -r commit; do
    files=$(git -C "$repo" diff-tree --no-commit-id --name-only -r "$commit")
    case "$files" in
        codex-rs/Cargo.lock|codex-rs/app-server-protocol/schema/precomputed/app-server-exports-experimental.json.zst) continue ;;
    esac
    git -C "$destination" cherry-pick "$commit"
done
node "$destination/desktop-wake/normalize-lock.mjs"
if ! git -C "$destination" diff --quiet -- codex-rs/Cargo.lock; then
    git -C "$destination" add codex-rs/Cargo.lock
    git -C "$destination" commit -m 'Align Cargo lock with bundled runtime version'
fi
printf 'Candidate checkout: %s\nRegenerate the experimental RPC schema, then build and verify the candidate before switching runtimes.\n' "$destination"
