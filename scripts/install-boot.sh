#!/bin/bash
# Update boot configuration / partition on the running system according to BOOT_TYPE.
# Dispatches to depthcharge (install-kpart.sh), uefi (boot/uefi.sh), or extlinux (boot/extlinux.sh).
#
# Usage: CONFIRM=yes /usr/libexec/lazyos/install-boot.sh [ARGS...]
set -euo pipefail
. "$(dirname "$0")/lib.sh"
. "$BOOT_BACKEND"

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
	sed -n '2,6p' "$0" | cut -c3-
	exit 0
fi

need_root
[ "${CONFIRM:-}" = "yes" ] ||
	die "refusing to modify boot configuration without CONFIRM=yes (CONFIRM=yes $(basename "$0"))"

boot_update_running "$@"
