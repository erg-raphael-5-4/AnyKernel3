#!/bin/bash
# Rooted RaphGhost kernel (KernelSU-Next) as an AnyKernel3 zip.
VARIANT=root exec "$(dirname "$(readlink -f "$0")")/build-kernel.sh" "$@"
