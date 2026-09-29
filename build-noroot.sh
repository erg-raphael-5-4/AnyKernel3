#!/bin/bash
# Non-rooted RaphGhost kernel (KernelSU-Next disabled) as an AnyKernel3 zip.
VARIANT=noroot exec "$(dirname "$(readlink -f "$0")")/build-kernel.sh" "$@"
