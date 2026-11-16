#!/bin/bash
# Partition and populate a microSD/USB device so it boots via depthcharge (pick
# the external disk in the firmware's developer-mode menu).
#
# The layout is Nura's (see scripts/lib-cgpt.sh):
#   p1  kernel  128 MiB  signed FIT kpart
#   p2  boot    512 MiB  kernel, initramfs, DTBs
#   p3  root    the rest Debian root filesystem
#
# Usage: write-sd.sh [DEVICE]     (default: /dev/mmcblk1)
set -euo pipefail
. "$(dirname "$0")/lib.sh"
. "$BOOT_BACKEND"

BLOCK="${1:-/dev/mmcblk1}"

if [ "$(id -u)" -ne 0 ]; then
	exec sudo -n DEVICE="$DEVICE" KERNEL_CMDLINE_OVERRIDE="${KERNEL_CMDLINE_OVERRIDE:-}" \
		LAZYOS_ROOT_DIR="${REPO_DIR:-}" LAZYOS_DEVICES_DIR="${DEVICES_REPO:-}" \
		LAZYOS_DESKTOP_DIR="${DESKTOP_REPO:-}" \
		"$(readlink -f "$0")" "${1:-}"
fi

[ -b "$BLOCK" ] || die "not a block device: $BLOCK"
[ -d "$ROOTFS" ] || die "rootfs not found: $ROOTFS (run build-rootfs.sh first)"
require_compositor "$ROOTFS"

# Safety: never touch the fixed internal storage or the running root device.
ROOT_SRC="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
if [ -n "${deviceinfo_install_target:-}" ]; then
	case "$BLOCK" in
		"$deviceinfo_install_target"|"$deviceinfo_install_target"p*|"$deviceinfo_install_target"[0-9]*)
			die "refusing to write to internal install target: $BLOCK" ;;
	esac
fi
case "$BLOCK" in
	*/mmcblk0|*/mmcblk0p*)
		if [ "$(cat /sys/block/mmcblk0/device/removable 2>/dev/null || echo fixed)" != "removable" ] &&
			[ "$(cat /sys/block/mmcblk0/removable 2>/dev/null || echo 0)" = 0 ]; then
			die "refusing to write to fixed internal mmcblk0: $BLOCK"
		fi
		;;
esac
case "$ROOT_SRC" in
	"$BLOCK"|"$BLOCK"p*|"$BLOCK"[0-9]*) die "refusing to write to the running root device: $BLOCK" ;;
esac

log "Device: $DEVICE -> $BLOCK ($(blockdev --getsize64 "$BLOCK") bytes)"
boot_release "$BLOCK"

log "Creating $BOOT_TYPE partition layout on $BLOCK"
boot_layout_create "$BLOCK"

MNT="$WORK_DIR/sd-mnt-$DEVICE"
boot_layout_mount "$BLOCK" "$MNT"

log "Copying root filesystem"
# A leftover mount under the rootfs (a chroot /proc or /sys someone forgot to
# unmount) is never wanted: rsync would copy the live host's pseudo-filesystems
# and fail on their unreadable entries - which is exactly what aborted a card
# write once - and on a slower medium it could write some of them first.
_stale_mounts="$(findmnt -rn -o TARGET 2>/dev/null | grep -F "$ROOTFS/" || true)"
[ -z "$_stale_mounts" ] ||
	die "something is mounted under $ROOTFS ($_stale_mounts); unmount it first"
rsync -aHAX --delete "$ROOTFS"/ "$MNT"/
boot_write_fstab "$MNT"

log "Installing $BOOT_TYPE boot target (root=UUID=$ROOT_UUID)"
boot_install "$MNT" "$BLOCK" "root=UUID=$ROOT_UUID rootwait rw"
boot_layout_umount "$MNT"

log "Done. Remove $BLOCK and boot the target system ($BOOT_TYPE)."
if [ "$BOOT_TYPE" = "depthcharge" ]; then
	cgpt show "$BLOCK" || true
else
	parted -s "$BLOCK" print || true
fi