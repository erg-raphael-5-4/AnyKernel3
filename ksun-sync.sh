#!/bin/bash
# Pull new KernelSU-Next legacy commits into the kernel's vendored copy
# (drivers/kernelsu). build-kernel.sh runs this before every KSUN build.
#
#   ./ksun-sync.sh             port new upstream commits, bump the version
#   KSUN_SYNC=0 ./build-root.sh   build without syncing
#
# drivers/kernelsu has no upstream history, so the last upstream commit it
# matches is recorded in drivers/kernelsu/ksun-version.mk ("Values for
# upstream legacy <sha>"). Every newer upstream commit is turned into a patch
# limited to kernel/ and uapi/, its paths are mapped to drivers/kernelsu/ and
# drivers/kernelsu/uapi/, and it is applied with git am, so the original
# author, date and message are kept (a port note is appended). Commits that
# only touch userspace or docs are skipped, as are commits whose change is
# already in the tree and the ones listed in ksun-skip.txt (our own work that
# upstream merged in a different form). A commit that doesn't apply stops
# the sync, and the build with it. Then KSU_VERSION_OVERRIDE is set to
# 30000 + the upstream commit count + 289. Nothing is pushed.
#
# Overridable environment:
#   KERNEL_DIR   kernel source (default: ../derp-17/kernel/xiaomi/sm8150)
#   KSUN_CACHE   bare clone of KernelSU-Next (default: ~/customrom/cache/KernelSU-Next.git)
#   KSUN_BRANCH  upstream branch (default: legacy)

set -euo pipefail

AK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_DIR="${KERNEL_DIR:-$(cd "$AK/../derp-17/kernel/xiaomi/sm8150" && pwd)}"
KSUN_CACHE="${KSUN_CACHE:-$HOME/customrom/cache/KernelSU-Next.git}"
KSUN_URL="https://github.com/KernelSU-Next/KernelSU-Next.git"
KSUN_BRANCH="${KSUN_BRANCH:-legacy}"
MK="$KERNEL_DIR/drivers/kernelsu/ksun-version.mk"
SKIP="$AK/ksun-skip.txt"

die() { echo "ksun-sync: $*" >&2; exit 1; }

last="$(sed -n 's/^# Values for upstream legacy \([0-9a-f]\{7,40\}\) .*/\1/p' "$MK")"
[ -n "$last" ] || die "no upstream commit recorded in $MK"

# Upstream cache. A failed fetch only warns, so an offline build still works.
if [ ! -d "$KSUN_CACHE" ]; then
    mkdir -p "$(dirname "$KSUN_CACHE")"
    git clone -q --bare --filter=blob:none -b "$KSUN_BRANCH" "$KSUN_URL" "$KSUN_CACHE"
fi
if ! git -C "$KSUN_CACHE" fetch -q origin "+refs/heads/$KSUN_BRANCH:refs/heads/$KSUN_BRANCH"; then
    echo "ksun-sync: WARNING: can't fetch $KSUN_URL; building drivers/kernelsu as it is" >&2
fi
up="$(git -C "$KSUN_CACHE" rev-parse "refs/heads/$KSUN_BRANCH")"
git -C "$KSUN_CACHE" merge-base --is-ancestor "$last" "$up" ||
    die "$last is not on upstream $KSUN_BRANCH any more (rewritten?); sync by hand"

mapfile -t commits < <(git -C "$KSUN_CACHE" rev-list --reverse --no-merges "$last..$up")
if [ "${#commits[@]}" -eq 0 ]; then
    echo "ksun-sync: drivers/kernelsu is up to date with $KSUN_BRANCH $(git -C "$KSUN_CACHE" rev-parse --short=12 "$up")"
    exit 0
fi

[ -z "$(git -C "$KERNEL_DIR" status --porcelain --untracked-files=no)" ] ||
    die "$KERNEL_DIR has uncommitted changes"
git -C "$KERNEL_DIR" symbolic-ref -q HEAD >/dev/null || die "$KERNEL_DIR is on a detached HEAD"

echo "ksun-sync: ${#commits[@]} new upstream $KSUN_BRANCH commit(s)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
ported=0
for c in "${commits[@]}"; do
    short="$(git -C "$KSUN_CACHE" rev-parse --short=12 "$c")"
    subject="$(git -C "$KSUN_CACHE" log -1 --format=%s "$c")"
    if [ -f "$SKIP" ] && grep -qE "^${short:0:12}" "$SKIP"; then
        echo "   skip $short (ksun-skip.txt): $subject"
        last="$c"
        continue
    fi
    p="$tmp/$short.patch"
    git -C "$KSUN_CACHE" format-patch -1 --stdout "$c" -- kernel uapi > "$p"
    # A new uapi version needs a ksud/manager that speaks it; with an older
    # one ksud's boot stages do nothing (no module scripts, no module
    # updates). Stop before such a commit, and before any listed as
    # "hold <sha>" in ksun-skip.txt, until the manager has caught up.
    if grep -qE '^[-+]#define KERNEL_SU_UAPI_VERSION' "$p" ||
            { [ -f "$SKIP" ] && grep -qE "^hold ${short:0:12}" "$SKIP"; }; then
        echo "ksun-sync: WARNING: holding at $short \"$subject\" (it changes the" >&2
        echo "ksun-sync:   KernelSU uapi version, or is on hold in ksun-skip.txt); it and" >&2
        echo "ksun-sync:   everything after it stay out until the manager supports it" >&2
        held=1
        break
    fi
    if ! grep -q '^diff --git ' "$p"; then
        echo "   skip $short (no kernel/ or uapi/ change): $subject"
        last="$c"
        continue
    fi
    sed -i -E \
        -e 's#^(diff --git a/)kernel/(.*) b/kernel/#\1drivers/kernelsu/\2 b/drivers/kernelsu/#' \
        -e 's#^(diff --git a/)uapi/(.*) b/uapi/#\1drivers/kernelsu/uapi/\2 b/drivers/kernelsu/uapi/#' \
        -e 's#^(--- a/|\+\+\+ b/)kernel/#\1drivers/kernelsu/#' \
        -e 's#^(--- a/|\+\+\+ b/)uapi/#\1drivers/kernelsu/uapi/#' \
        -e 's#^(rename (from|to) |copy (from|to) )kernel/#\1drivers/kernelsu/#' \
        -e 's#^(rename (from|to) |copy (from|to) )uapi/#\1drivers/kernelsu/uapi/#' "$p"
    if git -C "$KERNEL_DIR" apply --check -R "$p" 2>/dev/null; then
        echo "   skip $short (already in the tree): $subject"
        last="$c"
        continue
    fi
    # Ported earlier (by hand or by this script) and changed since, so the
    # reverse patch no longer applies: ports keep the author and subject.
    # (No grep -q: under pipefail its early exit would SIGPIPE git log.)
    author="$(git -C "$KSUN_CACHE" log -1 --format=%an "$c")"
    if git -C "$KERNEL_DIR" log --format='%an%x09%s' -- drivers/kernelsu |
            grep -xF "$author	$subject" >/dev/null; then
        echo "   skip $short (already ported, same author and subject): $subject"
        last="$c"
        continue
    fi
    if ! git -C "$KERNEL_DIR" am -q -3 "$p"; then
        git -C "$KERNEL_DIR" am --abort 2>/dev/null || true
        die "upstream $short \"$subject\" doesn't apply; port it by hand (patch: $p), or list it in $SKIP"
    fi
    msg="$(git -C "$KERNEL_DIR" log -1 --format=%B)"
    git -C "$KERNEL_DIR" commit -q --amend -m "$msg

[ergdevops: vendored into drivers/kernelsu (kernel/ -> drivers/kernelsu/,
 uapi/ -> drivers/kernelsu/uapi/). Upstream KernelSU-Next $KSUN_BRANCH
 $short.]"
    echo "   port $short -> $(git -C "$KERNEL_DIR" rev-parse --short=12 HEAD): $subject"
    ported=$((ported + 1))
    last="$c"
done

# Record the new upstream position and the version the manager should see:
# upstream's head, or the last commit taken when the sync stopped at a hold.
[ -n "${held:-}" ] && up="$last"
upshort="$(git -C "$KSUN_CACHE" rev-parse --short=12 "$up")"
count="$(git -C "$KSUN_CACHE" rev-list --count "$up")"
version=$((30000 + count + 289))
sed -i -E \
    -e "s/^# Values for upstream legacy [0-9a-f]+ \(([^)]*)\): 30000 \+ rev-list count [0-9]+ \+ 289\./# Values for upstream legacy $upshort (\1): 30000 + rev-list count $count + 289./" \
    -e "s/^KSU_VERSION_OVERRIDE := [0-9]+$/KSU_VERSION_OVERRIDE := $version/" "$MK"
if [ -n "$(git -C "$KERNEL_DIR" status --porcelain -- "$MK")" ]; then
    git -C "$KERNEL_DIR" commit -q -m "kernelsu: Bump the version override to upstream legacy $upshort

drivers/kernelsu now matches upstream KernelSU-Next $KSUN_BRANCH $upshort
(rev-list count $count), so report 30000 + $count + 289 = $version to the
manager." -- "$MK"
fi
echo "ksun-sync: ported $ported, now at $KSUN_BRANCH $upshort (KSU version $version)${held:+, held back from newer commits}; nothing pushed"
