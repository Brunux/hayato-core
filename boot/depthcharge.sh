#!/bin/bash
# ChromeOS Depthcharge boot backend (cgpt + depthchargectl signed FIT kpart).
# Implements the uniform hayato-core boot_* interface over scripts/lib-cgpt.sh.

. "${CORE_SCRIPTS_DIR:-$CORE_DIR/scripts}/lib-cgpt.sh"

boot_release() {
	disk_release "$1"
}

boot_layout_create() {
	local disk="$1"
	disk_layout_create "$disk"
	disk_layout_parts "$disk"
}

boot_layout_mount() {
	local disk="$1" mnt="$2"
	disk_layout_parts "$disk"
	disk_layout_mount "$disk" "$mnt"
}

boot_layout_umount() {
	disk_layout_umount "$1"
}

boot_write_fstab() {
	disk_layout_fstab "$1"
}

# Build ChromeOS FIT kpart from <rootfs> and write to <out_or_block_dev>.
# If <out> is a block device node (whole disk), resolves p1 via disk_layout_parts
# and flashes + verifies it; otherwise writes the .kpart file at <out>.
boot_install() {
	local rootfs="$1" out="$2" cmdline_extra="${3:-}"
	if [ -b "$out" ]; then
		disk_layout_parts "$out"
		local kpart_tmp="$WORK_DIR/${DEVICE}.depthcharge.kpart"
		"${CORE_SCRIPTS_DIR:-$CORE_DIR/scripts}/make-kpart.sh" "$rootfs" "$kpart_tmp" "$cmdline_extra"
		kpart_fits "$kpart_tmp" "$KPART_PART"
		log "Writing signed kpart to $KPART_PART"
		dd if="$kpart_tmp" of="$KPART_PART" bs=1M conv=fsync status=progress
		sync
		kpart_verify "$KPART_PART"
	else
		"${CORE_SCRIPTS_DIR:-$CORE_DIR/scripts}/make-kpart.sh" "$rootfs" "$out" "$cmdline_extra"
	fi
}

# Rewrites the running system's ChromeOS kernel partition (kern_guid from /proc/cmdline).
boot_update_running() {
	exec "${CORE_SCRIPTS_DIR:-$CORE_DIR/scripts}/install-kpart.sh" "$@"
}
