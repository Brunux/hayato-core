#!/bin/bash
# Standard U-Boot / SBC extlinux.conf boot backend (GPT /boot + ext4 root).
# Implements the uniform hayato-core boot_* interface.

EXTLINUX_BOOT_MIB="${deviceinfo_boot_size_mib:-$BOOT_SIZE_MIB}"

_extlinux_wait_parts() {
	local disk="$1"
	partprobe "$disk" 2>/dev/null || true
	partx -d "$disk" 2>/dev/null || true
	partx -a "$disk" 2>/dev/null || blockdev --rereadpt "$disk" 2>/dev/null || true
	command -v udevadm >/dev/null 2>&1 && udevadm settle || sleep 2
}

_extlinux_ensure_part_node() {
	local disk="$1" partn="$2" part="" sys="" devnum="" kname=""
	part="$(lsblk -nro PATH,PARTN "$disk" 2>/dev/null | awk -v n="$partn" '$2 == n { print $1; exit }')"
	if [ -n "$part" ] && [ -b "$part" ]; then
		printf '%s\n' "$part"
		return 0
	fi
	kname="$(basename "$disk")"
	for sys in "/sys/block/${kname}/${kname}p${partn}" "/sys/block/${kname}/${kname}${partn}"; do
		if [ -r "$sys/dev" ]; then
			devnum="$(tr -d ' \t\r\n' <"$sys/dev")"
			case "$disk" in
			*[0-9]) part="${disk}p${partn}" ;;
			*) part="${disk}${partn}" ;;
			esac
			if [ ! -b "$part" ] && [ -n "${devnum%:*}" ] && [ -n "${devnum#*:}" ]; then
				mknod -m 0660 "$part" b "${devnum%:*}" "${devnum#*:}" 2>/dev/null || true
			fi
			if [ -b "$part" ]; then
				printf '%s\n' "$part"
				return 0
			fi
		fi
	done
	printf '%s\n' "$part"
}

_extlinux_parts() {
	local disk="$1"
	BOOT_PART="$(_extlinux_ensure_part_node "$disk" 1)"
	ROOT_PART="$(_extlinux_ensure_part_node "$disk" 2)"
	[ -n "$BOOT_PART" ] && [ -n "$ROOT_PART" ] || die "could not resolve extlinux partitions on $disk"
	[ "$BOOT_PART" != "$disk" ] && [ "$ROOT_PART" != "$disk" ] ||
		die "refusing to operate on whole disk $disk"
}

boot_release() {
	local disk="$1" p
	for p in "$disk" "${disk}p"* "${disk}"[0-9]*; do
		[ -b "$p" ] || continue
		if findmnt -rn -S "$p" >/dev/null 2>&1 || grep -qs "^$p " /proc/mounts; then
			die "$p is mounted; unmount it first (udisksctl unmount -b $p)"
		fi
		swapoff "$p" 2>/dev/null || true
	done
	if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet udisks2 2>/dev/null; then
		die "udisks2 is running; stop it first: sudo systemctl stop udisks2"
	fi
}

boot_layout_create() {
	local disk="$1"
	[ "$EXTLINUX_BOOT_MIB" -ge 256 ] || die "EXTLINUX_BOOT_MIB=$EXTLINUX_BOOT_MIB too small (need >= 256 MiB)"
	local boot_start="${deviceinfo_extlinux_start_mib:-16}"
	local boot_end="$((boot_start + EXTLINUX_BOOT_MIB))MiB"
	parted -s "$disk" \
		mktable gpt \
		mkpart hayato_boot "$BOOT_FS" "${boot_start}MiB" "$boot_end" \
		set 1 legacy_boot on \
		mkpart hayato_root ext4 "$boot_end" 100%
	_extlinux_wait_parts "$disk"
	_extlinux_parts "$disk"
}

boot_layout_mount() {
	local disk="$1" mnt="$2"
	_extlinux_parts "$disk"
	log "Formatting $BOOT_PART ($BOOT_FS, label hayato_boot)"
	"mkfs.$BOOT_FS" -F -q -L hayato_boot "$BOOT_PART" >/dev/null
	BOOT_UUID="$(blkid -s UUID -o value "$BOOT_PART")"
	log "Formatting $ROOT_PART (ext4, label hayato_root)"
	mkfs.ext4 -F -q -L hayato_root "$ROOT_PART" >/dev/null
	ROOT_UUID="$(blkid -s UUID -o value "$ROOT_PART")"
	[ -n "$BOOT_UUID" ] && [ -n "$ROOT_UUID" ] || die "could not read partition UUIDs on $disk"

	mkdir -p "$mnt"
	mount "$ROOT_PART" "$mnt"
	mkdir -p "$mnt/boot"
	mount "$BOOT_PART" "$mnt/boot"
}

boot_layout_umount() {
	local mnt="$1"
	mountpoint -q "$mnt/boot" && umount "$mnt/boot" || true
	mountpoint -q "$mnt" && umount "$mnt" || true
}

boot_write_fstab() {
	local mnt="$1"
	cat >"$mnt/etc/fstab" <<EOF
UUID=$ROOT_UUID	/	ext4	defaults	0 1
UUID=$BOOT_UUID	/boot	$BOOT_FS	nodev,nosuid,noexec	0 2
EOF
}

# Write /boot/extlinux/extlinux.conf inside <rootfs>.
boot_install() {
	local rootfs="$1" _target="${2:-}" cmdline_extra="${3:-}"
	local boot="$rootfs/boot"
	local vmlinuz initrd cmdline rel dtb_rel=""

	vmlinuz="$(ls -1 "$boot"/vmlinuz-* 2>/dev/null | sort -V | tail -n1)"
	[ -f "$vmlinuz" ] || die "no vmlinuz-* in $boot"
	rel="$(basename "$vmlinuz")"
	rel="${rel#vmlinuz-}"
	initrd="$boot/initrd.img-$rel"
	[ -f "$initrd" ] || die "no initrd.img-$rel in $boot"

	cmdline="$(_boot_build_cmdline "$rootfs" "$cmdline_extra")"

	if [ -n "${deviceinfo_dtb:-}" ] && [ -d "$boot/dtbs" ]; then
		local dtb_count dtb_match
		dtb_count="$(find "$boot/dtbs" -type f -path "$boot/dtbs/$deviceinfo_dtb" 2>/dev/null | wc -l)"
		if [ "$dtb_count" -eq 1 ]; then
			dtb_match="$(find "$boot/dtbs" -type f -path "$boot/dtbs/$deviceinfo_dtb" 2>/dev/null | head -n1)"
			dtb_rel="${dtb_match#"$boot/dtbs/"}"
		fi
	fi

	mkdir -p "$boot/extlinux"
	{
		printf 'TIMEOUT 10\n'
		printf 'DEFAULT hayato\n\n'
		printf 'LABEL hayato\n'
		printf '    MENU LABEL Hayato (%s)\n' "$rel"
		printf '    LINUX /vmlinuz-%s\n' "$rel"
		printf '    INITRD /initrd.img-%s\n' "$rel"
		if [ -n "$dtb_rel" ]; then
			printf '    FDT /dtbs/%s\n' "$dtb_rel"
		elif [ -d "$boot/dtbs" ]; then
			printf '    FDTDIR /dtbs/\n'
		fi
		printf '    APPEND %s\n' "$cmdline"
	} >"$boot/extlinux/extlinux.conf"
	log "extlinux entry written ($boot/extlinux/extlinux.conf)"
}

boot_update_running() {
	local root_uuid extra="" tok
	root_uuid="$(findmnt -n -o UUID / 2>/dev/null || true)"
	[ -n "$root_uuid" ] && extra="root=UUID=$root_uuid rootwait rw"
	if [ -r /proc/cmdline ]; then
		for tok in $(cat /proc/cmdline); do
			case "$tok" in
				resume=*|resume_offset=*) extra="${extra:+$extra }$tok" ;;
			esac
		done
	fi
	boot_install / / "$extra"
}

# Optional hook for future SoCs that require raw U-Boot/SPL sector writes on disk.
boot_flash_spl() {
	:
}
