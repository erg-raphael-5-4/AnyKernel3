#!/bin/bash
# Rooted RaphGhost kernel (KernelSU-Next) with Droidspaces container support
# as an AnyKernel3 zip.
VARIANT=droidspaces exec "$(dirname "$(readlink -f "$0")")/build-kernel.sh" "$@"
