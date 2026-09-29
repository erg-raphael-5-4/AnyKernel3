#!/bin/bash
# Publish the newest rooted and non-rooted AnyKernel3 zips from out/ as a
# GitHub release on the kernel repo.
#
#   ./release.sh                 newest root + noroot zips, tag from the kernel version
#   ./release.sh --draft         create the release as a draft
#   TAG=RaphGhost-v2 ./release.sh
#
# Overridable environment:
#   REPO        GitHub repo (default: erg-raphael-5-4/android_kernel_xiaomi_sm8150)
#   BRANCH      branch the release tag points at (default: derp-17)
#   KERNEL_DIR  kernel source, used for the commit and changelog
#               (default: ../derp-17/kernel/xiaomi/sm8150)
#   NOTES       release notes file (default: generated)
#
# Both zips must be built from the same kernel commit; the script refuses to
# mix builds. Requires an authenticated `gh`.

set -euo pipefail

AK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${REPO:-erg-raphael-5-4/android_kernel_xiaomi_sm8150}"
BRANCH="${BRANCH:-derp-17}"
KERNEL_DIR="${KERNEL_DIR:-$AK/../derp-17/kernel/xiaomi/sm8150}"
DRAFT=""
[ "${1:-}" = "--draft" ] && DRAFT="--draft"

newest() { ls -t "$AK"/out/RaphGhost-*-"$1"-*.zip 2>/dev/null | head -1; }
ROOT_ZIP="$(ls -t "$AK"/out/RaphGhost-*-KSUN-*.zip 2>/dev/null | head -1)"
NOROOT_ZIP="$(newest NoRoot)"
[ -n "$ROOT_ZIP" ] || { echo "no rooted zip in out/ (run ./build-root.sh)" >&2; exit 1; }
[ -n "$NOROOT_ZIP" ] || { echo "no non-rooted zip in out/ (run ./build-noroot.sh)" >&2; exit 1; }

# Kernel release string, e.g. 5.4.302-RaphGhost-g3ffe7e660240
krel() { basename "$1" | sed -E 's/^RaphGhost-(.*)-(KSUN-.*|NoRoot)-[0-9]{8}-[0-9]{4}\.zip$/\1/'; }
KREL_ROOT="$(krel "$ROOT_ZIP")"
KREL_NOROOT="$(krel "$NOROOT_ZIP")"
[ "$KREL_ROOT" = "$KREL_NOROOT" ] || {
    echo "zips are from different kernels: $KREL_ROOT vs $KREL_NOROOT" >&2; exit 1; }
KREL="$KREL_ROOT"
case "$KREL" in *-dirty) echo "refusing to release a -dirty kernel ($KREL)" >&2; exit 1;; esac

SHORT="${KREL##*-g}"
COMMIT="$(git -C "$KERNEL_DIR" rev-parse --verify -q "$SHORT^{commit}")" || {
    echo "kernel commit $SHORT not found in $KERNEL_DIR" >&2; exit 1; }
git -C "$KERNEL_DIR" fetch -q "git@github.com:$REPO.git" "$BRANCH" 2>/dev/null || true
if ! git -C "$KERNEL_DIR" merge-base --is-ancestor "$COMMIT" FETCH_HEAD 2>/dev/null; then
    echo "commit $COMMIT is not on $REPO $BRANCH yet - push the kernel first" >&2; exit 1
fi

TAG="${TAG:-RaphGhost-$(echo "$KREL" | sed 's/-RaphGhost//')-$(date +%Y%m%d)}"
KSU_TAG="$(basename "$ROOT_ZIP" | sed -E 's/.*-KSUN-(.*)-[0-9]{8}-[0-9]{4}\.zip$/\1/')"

if [ -z "${NOTES:-}" ]; then
    NOTES="$(mktemp)"
    PREV="$(gh release list -R "$REPO" --limit 1 --json tagName --jq '.[0].tagName' 2>/dev/null || true)"
    {
        echo "RaphGhost kernel for raphael (Redmi K20 Pro / Mi 9T Pro), Linux ${KREL%%-*}."
        echo
        echo "- \`$(basename "$ROOT_ZIP")\` - rooted, KernelSU-Next $KSU_TAG"
        echo "- \`$(basename "$NOROOT_ZIP")\` - no root"
        echo
        echo "Flash either zip from recovery (AnyKernel3). It replaces the kernel,"
        echo "dtb and dtbo and keeps the ROM's boot ramdisk."
        echo
        echo "Kernel commit: \`$SHORT\` ($BRANCH)"
        echo
        echo "MD5:"
        echo "\`\`\`"
        echo "$(cat "$ROOT_ZIP.md5")  $(basename "$ROOT_ZIP")"
        echo "$(cat "$NOROOT_ZIP.md5")  $(basename "$NOROOT_ZIP")"
        echo "\`\`\`"
        if [ -n "$PREV" ]; then
            PREV_COMMIT="$(gh release view "$PREV" -R "$REPO" --json targetCommitish --jq .targetCommitish 2>/dev/null || true)"
            if [ -n "$PREV_COMMIT" ] && git -C "$KERNEL_DIR" cat-file -e "$PREV_COMMIT^{commit}" 2>/dev/null; then
                echo
                echo "Changes since $PREV:"
                git -C "$KERNEL_DIR" log --no-merges --format='- %s' "$PREV_COMMIT..$COMMIT"
            fi
        fi
    } > "$NOTES"
fi

echo "Repo:    $REPO"
echo "Tag:     $TAG -> $COMMIT"
echo "Assets:  $(basename "$ROOT_ZIP")"
echo "         $(basename "$NOROOT_ZIP")"
echo
cat "$NOTES"
echo
read -r -p "Publish this release? [y/N] " ok
[ "$ok" = y ] || [ "$ok" = Y ] || { echo "aborted"; exit 1; }

gh release create "$TAG" -R "$REPO" --target "$COMMIT" --title "$TAG" \
    --notes-file "$NOTES" $DRAFT \
    "$ROOT_ZIP" "$ROOT_ZIP.md5" "$NOROOT_ZIP" "$NOROOT_ZIP.md5"
