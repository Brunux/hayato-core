#!/bin/bash
# Install hayato-core and hayato-device-<device> packages into ROOTFS (or `/`).
#
# Usage: install-core.sh [ROOTFS]
set -euo pipefail
. "$(dirname "$0")/lib.sh"

[ -n "${1:-}" ] && ROOTFS="$1"
ROOTFS="$(readlink -f "$ROOTFS" 2>/dev/null || printf '%s' "$ROOTFS")"

[ -f "$ROOTFS/var/lib/dpkg/status" ] ||
	die "not a root filesystem: $ROOTFS/var/lib/dpkg/status is missing"
ls "$HAYATO_STAGE"/hayato-core_*.deb >/dev/null 2>&1 ||
	die "no hayato-core package in $HAYATO_STAGE (run build-core-deb.sh first)"

if [ "$(id -u)" -ne 0 ]; then
	exec sudo -n \
		BUILD_ROOT="$BUILD_ROOT" WORK_DIR="$WORK_DIR" SRC_DIR="$SRC_DIR" \
		DEVICE="$DEVICE" ROOTFS="$ROOTFS" \
		HAYATO_ROOT_DIR="${REPO_DIR:-}" HAYATO_DEVICES_DIR="${DEVICES_REPO:-}" \
		HAYATO_DESKTOP_DIR="${DESKTOP_REPO:-}" \
		"$(readlink -f "$0")"
fi

DEBS=("$HAYATO_STAGE"/hayato-core_*.deb)
if ls "$HAYATO_STAGE"/hayato-device-"${DEVICE}"_*.deb >/dev/null 2>&1; then
	DEBS+=("$HAYATO_STAGE"/hayato-device-"${DEVICE}"_*.deb)
fi

if [ "$ROOTFS" = "/" ]; then
	log "Installing hayato-core and device packages on the running system"
	dpkg --force-confdef --force-confnew -i "${DEBS[@]}"
else
	log "Installing hayato-core and device packages into $ROOTFS"
	STAGE_IN_CHROOT="/var/tmp/hayato-core-debs"
	rm -rf "$ROOTFS$STAGE_IN_CHROOT"
	mkdir -p "$ROOTFS$STAGE_IN_CHROOT"
	cp "${DEBS[@]}" "$ROOTFS$STAGE_IN_CHROOT/"

	mount --bind /dev "$ROOTFS/dev"
	mount -t proc proc "$ROOTFS/proc"
	mount -t sysfs sys "$ROOTFS/sys"
	cleanup() {
		rm -rf "$ROOTFS$STAGE_IN_CHROOT"
		for m in dev proc sys; do
			umount -lf "$ROOTFS/$m" 2>/dev/null || true
		done
	}
	trap cleanup EXIT

	chroot "$ROOTFS" /bin/bash -c \
		"dpkg --force-confdef --force-confnew -i $STAGE_IN_CHROOT/*.deb"
fi
log "hayato-core and device packages installed"
