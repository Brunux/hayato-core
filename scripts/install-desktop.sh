#!/bin/bash
# Install staged desktop packages and binaries (swayfx, workstyle, hayato, RetroArch, N64 core) into ROOTFS.
#
# Usage: install-desktop.sh [ROOTFS]
set -euo pipefail
. "$(dirname "$0")/lib.sh"

ROOTFS_TARGET="${1:-$ROOTFS}"

"$CORE_DIR/scripts/install-swayfx.sh" "$ROOTFS_TARGET"
"$CORE_DIR/scripts/install-workstyle.sh" "$ROOTFS_TARGET"
"$CORE_DIR/scripts/install-hayato.sh" "$ROOTFS_TARGET"
"$CORE_DIR/scripts/install-retroarch.sh" "$ROOTFS_TARGET"
