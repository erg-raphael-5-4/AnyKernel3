#!/bin/bash
# Build the RaphGhost kernel from the derp-17 kernel tree and package it as an
# AnyKernel3 flashable zip. Called by build-root.sh, build-noroot.sh and
# build-droidspaces.sh.
#
#   VARIANT=root|noroot|droidspaces ./build-kernel.sh
#
# Overridable environment:
#   TOP         Android tree that provides the prebuilt toolchain and host tools
#               (default: ../derp-17)
#   KERNEL_DIR  kernel source (default: $TOP/kernel/xiaomi/sm8150)
#   JOBS        parallel jobs (default: 6)
#   CLEAN=1     wipe this variant's build directory first
#
# The kernel is configured exactly like the ROM build (vendor/lineage
# build/tasks/kernel.mk): sm8150-qgki_defconfig, then each fragment merged with
# merge_config.sh and olddefconfig. The noroot variant merges one more fragment
# (configs/noroot.config) that disables KernelSU-Next; the droidspaces variant
# is the rooted build plus configs/droidspaces.config (container support). The
# kernel tree itself is never modified.

set -euo pipefail

AK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VARIANT="${VARIANT:?set VARIANT=root, noroot or droidspaces}"
TOP="${TOP:-$(cd "$AK/../derp-17" && pwd)}"
KERNEL_DIR="${KERNEL_DIR:-$TOP/kernel/xiaomi/sm8150}"
JOBS="${JOBS:-6}"

case "$VARIANT" in
    root|noroot|droidspaces) ;;
    *) echo "VARIANT must be root, noroot or droidspaces" >&2; exit 1 ;;
esac

CLANG="$TOP/prebuilts/clang/host/linux-x86/clang-r596125"
HOSTBIN="$TOP/out/host/linux-x86/bin"
for p in "$KERNEL_DIR/Makefile" "$CLANG/bin/clang" "$HOSTBIN/dtc" "$HOSTBIN/mkdtboimg"; do
    [ -e "$p" ] || { echo "missing: $p (build the ROM tree once so host tools exist)" >&2; exit 1; }
done

WORK="$AK/work/$VARIANT"
KOUT="$WORK/kernel"
[ "${CLEAN:-0}" = 1 ] && rm -rf "$WORK"
mkdir -p "$KOUT" "$AK/out"

# Configuration fragments, in the ROM's order.
DEFCONFIG="$KERNEL_DIR/arch/arm64/configs/vendor/sm8150-qgki_defconfig"
FRAGMENTS=(
    "$KERNEL_DIR/arch/arm64/configs/vendor/debugfs.config"
    "$KERNEL_DIR/arch/arm64/configs/vendor/xiaomi/sm8150-common.config"
    "$KERNEL_DIR/arch/arm64/configs/vendor/xiaomi/raphael.config"
)
[ "$VARIANT" = noroot ] && FRAGMENTS+=("$AK/configs/noroot.config")
[ "$VARIANT" = droidspaces ] && FRAGMENTS+=("$AK/configs/droidspaces.config")

SYSROOT="$TOP/prebuilts/gcc/linux-x86/host/x86_64-linux-glibc2.17-4.8/sysroot"
KBT="$TOP/prebuilts/kernel-build-tools/linux-x86"
BT="$TOP/prebuilts/build-tools/linux-x86/bin"

export PATH="$HOSTBIN:$CLANG/bin:$TOP/prebuilts/tools-lineage/linux-x86/bin:$BT:$TOP/prebuilts/clang-tools/linux-x86/bin:$PATH"
export LD_LIBRARY_PATH="$CLANG/lib64:${LD_LIBRARY_PATH:-}"
export HIP_PATH=none
export PERL5LIB="$TOP/prebuilts/tools-lineage/common/perl-base"
export BISON_PKGDATADIR="$TOP/prebuilts/build-tools/common/bison"

kmake() {
    "$BT/make" -j"$JOBS" -C "$KERNEL_DIR" O="$KOUT" ARCH=arm64 \
        CLANG_TRIPLE=aarch64-linux-gnu- CC=clang LD=ld.lld LLVM=1 LLVM_IAS=1 \
        KBUILD_BUILD_USER=RaphGhost KBUILD_BUILD_HOST=RaphGhost \
        HOSTCFLAGS="--sysroot=$SYSROOT -I$KBT/include" \
        HOSTLDFLAGS="--sysroot=$SYSROOT -Wl,-rpath,$KBT/lib64 -L $KBT/lib64 -fuse-ld=lld --rtlib=compiler-rt" \
        LZ4="$KBT/bin/lz4" LEX="$BT/flex" YACC="$BT/bison" M4="$BT/m4" \
        DTC_EXT="$HOSTBIN/dtc" "$@"
}

echo "== Configuring ($VARIANT)"
cp "$DEFCONFIG" "$KOUT/.config"
kmake olddefconfig >/dev/null
for f in "${FRAGMENTS[@]}"; do
    ( cd "$KOUT" && "$KERNEL_DIR/scripts/kconfig/merge_config.sh" -m -O "$KOUT" "$KOUT/.config" "$f" >/dev/null )
    kmake olddefconfig >/dev/null
done
if [ "$VARIANT" = noroot ]; then
    grep -q "^CONFIG_KSU=y" "$KOUT/.config" && { echo "CONFIG_KSU still enabled" >&2; exit 1; }
else
    grep -q "^CONFIG_KSU=y" "$KOUT/.config" || { echo "CONFIG_KSU not enabled" >&2; exit 1; }
fi
if [ "$VARIANT" = droidspaces ]; then
    # merge_config.sh drops options whose dependencies aren't met; fail
    # instead of shipping a zip that silently lacks them.
    missing=$(grep -oE "^CONFIG_[A-Z0-9_]+=y" "$AK/configs/droidspaces.config" |
        while read -r opt; do grep -qx "$opt" "$KOUT/.config" || echo "$opt"; done)
    [ -z "$missing" ] || { echo "droidspaces options not applied:" $missing >&2; exit 1; }
fi

echo "== Building Image.gz and dtbs"
kmake Image.gz dtbs

# dtb.img: every built .dtb, sorted and concatenated (TARGET_DTB_LIST_WILDCARD=*).
DTS="$KOUT/arch/arm64/boot/dts"
find "$DTS" -type f -name "*.dtb" | sort | xargs cat > "$WORK/dtb"
# dtbo.img: mkdtboimg over every built overlay (BOARD_KERNEL_SEPARATED_DTBO).
mkdtboimg create "$WORK/dtbo.img" --page_size=4096 $(find "$DTS" -type f -name "*.dtbo" | sort)

KREL="$(cat "$KOUT/include/config/kernel.release")"
if [ "$VARIANT" != noroot ]; then
    KSU_TAG="$(sed -n 's/^KSU_VERSION_TAG_OVERRIDE := //p' "$KERNEL_DIR/drivers/kernelsu/ksun-version.mk" 2>/dev/null || true)"
    LABEL="KSUN-${KSU_TAG:-unknown}"
    STRING="RaphGhost $KREL (KernelSU-Next ${KSU_TAG:-}) by ergdev"
    if [ "$VARIANT" = droidspaces ]; then
        LABEL="$LABEL-Droidspaces"
        STRING="RaphGhost $KREL (KernelSU-Next ${KSU_TAG:-}, Droidspaces) by ergdev"
    fi
else
    LABEL="NoRoot"
    STRING="RaphGhost $KREL (no root) by ergdev"
fi

echo "== Packaging"
STAGE="$WORK/ak3"
rm -rf "$STAGE"
cp -a "$AK/template" "$STAGE"
sed -i "s|@KERNEL_STRING@|$STRING|" "$STAGE/anykernel.sh"
cp "$KOUT/arch/arm64/boot/Image.gz" "$STAGE/Image.gz"
cp "$WORK/dtb" "$STAGE/dtb"
cp "$WORK/dtbo.img" "$STAGE/dtbo.img"

ZIP="$AK/out/RaphGhost-$KREL-$LABEL-$(date +%Y%m%d-%H%M).zip"
( cd "$STAGE" && zip -qr9 "$ZIP" . )
md5sum "$ZIP" | cut -d' ' -f1 > "$ZIP.md5"

echo
echo "Kernel:  $KREL"
echo "Variant: $VARIANT ($STRING)"
echo "Zip:     $ZIP"
echo "MD5:     $(cat "$ZIP.md5")"
