#!/bin/bash
# Install the staged kernel (modules, vmlinuz, dtbs) into a rootfs and build its initramfs.
#
# Usage: install-kernel.sh [ROOTFS]
set -euo pipefail
. "$(dirname "$0")/lib.sh"

[ -n "${1:-}" ] && ROOTFS="$1"

if [ "$(id -u)" -ne 0 ]; then
	exec sudo -n DEVICE="$DEVICE" KERNEL_STAGE="$KERNEL_STAGE" \
		KERNEL_SOURCE_TYPE="${KERNEL_SOURCE_TYPE:-source}" KERNEL_RELEASE="${KERNEL_RELEASE:-}" \
		HAYATO_ROOT_DIR="${REPO_DIR:-}" HAYATO_DEVICES_DIR="${DEVICES_REPO:-}" \
		HAYATO_DESKTOP_DIR="${DESKTOP_REPO:-}" \
		"$(readlink -f "$0")" "${1:-}"
fi

[ -d "$ROOTFS" ] || die "rootfs not found: $ROOTFS (run build-rootfs.sh first)"

if [ "${KERNEL_SOURCE_TYPE:-source}" = "debian-pkg" ]; then
	resolve_kernel_release "$ROOTFS"
	[ -d "$ROOTFS/lib/modules/$KERNEL_RELEASE" ] ||
		die "no modules for packaged kernel $KERNEL_RELEASE in $ROOTFS/lib/modules"
	[ -f "$ROOTFS/boot/vmlinuz-$KERNEL_RELEASE" ] || [ -f "$ROOTFS/boot/vmlinux-$KERNEL_RELEASE" ] ||
		die "packaged kernel image missing in $ROOTFS/boot for $KERNEL_RELEASE"
	log "Using Debian packaged kernel $KERNEL_RELEASE"
	if [ -d "$ROOTFS/usr/lib/linux-image-$KERNEL_RELEASE" ]; then
		log "Syncing packaged DTBs (/usr/lib/linux-image-$KERNEL_RELEASE -> /boot/dtbs)"
		rm -rf "$ROOTFS/boot/dtbs"
		mkdir -p "$ROOTFS/boot/dtbs"
		cp -a "$ROOTFS/usr/lib/linux-image-$KERNEL_RELEASE/." "$ROOTFS/boot/dtbs/"
	fi
else
	[ -d "$KERNEL_STAGE/lib/modules/$KERNEL_RELEASE" ] || die "staged kernel not found: $KERNEL_STAGE (run build-kernel.sh first)"

	log "Installing modules for $KERNEL_RELEASE"
	mkdir -p "$ROOTFS/lib/modules"
	rm -rf "$ROOTFS/lib/modules/$KERNEL_RELEASE"
	cp -a "$KERNEL_STAGE/lib/modules/$KERNEL_RELEASE" "$ROOTFS/lib/modules/"

	log "Installing vmlinuz / config / dtbs"
	mkdir -p "$ROOTFS/boot/dtbs"
	# The kernel 'zinstall' target names the image vmlinuz-<release> (no plain vmlinuz).
	KERNEL_IMG="$KERNEL_STAGE/boot/vmlinuz-$KERNEL_RELEASE"
	[ -f "$KERNEL_IMG" ] || die "staged kernel image not found: $KERNEL_IMG"
	cp "$KERNEL_IMG" "$ROOTFS/boot/vmlinuz-$KERNEL_RELEASE"
	[ -f "$KERNEL_STAGE/boot/config" ] && cp "$KERNEL_STAGE/boot/config" "$ROOTFS/boot/config-$KERNEL_RELEASE"
	[ -f "$KERNEL_STAGE/boot/System.map" ] && cp "$KERNEL_STAGE/boot/System.map" "$ROOTFS/boot/System.map-$KERNEL_RELEASE"
	cp -a "$KERNEL_STAGE/boot/dtbs/." "$ROOTFS/boot/dtbs/"
fi

# Force the device's early modules into the initramfs.
if [ -n "$INITFS_MODULES" ]; then
	log "Adding initramfs modules: $INITFS_MODULES"
	mkdir -p "$ROOTFS/etc/initramfs-tools"
	touch "$ROOTFS/etc/initramfs-tools/modules"
	for m in $INITFS_MODULES; do
		grep -qxF "$m" "$ROOTFS/etc/initramfs-tools/modules" || echo "$m" >>"$ROOTFS/etc/initramfs-tools/modules"
	done
fi

if [ -f "$ROOTFS/etc/debian-aarch64-revision" ]; then
	sed -i "s|^kernel .*|kernel $KERNEL_RELEASE|" "$ROOTFS/etc/debian-aarch64-revision"
fi

log "depmod + initramfs"
mount --bind /dev "$ROOTFS/dev"
mount -t proc proc "$ROOTFS/proc"
mount -t sysfs sys "$ROOTFS/sys"
cleanup() {
	for m in dev proc sys; do
		umount -lf "$ROOTFS/$m" 2>/dev/null || true
	done
}
trap cleanup EXIT
chroot "$ROOTFS" depmod -a "$KERNEL_RELEASE"
if [ -f "$ROOTFS/boot/initrd.img-$KERNEL_RELEASE" ]; then
	chroot "$ROOTFS" update-initramfs -u -k "$KERNEL_RELEASE"
else
	chroot "$ROOTFS" update-initramfs -c -k "$KERNEL_RELEASE"
fi

log "Kernel installed into $ROOTFS"
ls -la "$ROOTFS/boot"
