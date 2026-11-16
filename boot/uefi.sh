#!/bin/bash
# Standard UEFI EBBR boot backend (GPT EFI System Partition + ext4 root + systemd-boot).
# Implements the uniform lazyos-core boot_* interface.

UEFI_ESP_MIB="${deviceinfo_boot_size_mib:-256}"

_uefi_wait_parts() {
	local disk="$1"
	partprobe "$disk" 2>/dev/null || true
	partx -d "$disk" 2>/dev/null || true
	partx -a "$disk" 2>/dev/null || blockdev --rereadpt "$disk" 2>/dev/null || true
	command -v udevadm >/dev/null 2>&1 && udevadm settle || sleep 2
}

_uefi_parts() {
	local disk="$1"
	EFI_PART="$(lsblk -nro PATH,PARTN "$disk" | awk '$2 == 1 { print $1; exit }')"
	ROOT_PART="$(lsblk -nro PATH,PARTN "$disk" | awk '$2 == 2 { print $1; exit }')"
	[ -n "$EFI_PART" ] && [ -n "$ROOT_PART" ] || die "could not resolve UEFI partitions on $disk"
	[ "$EFI_PART" != "$disk" ] && [ "$ROOT_PART" != "$disk" ] ||
		die "refusing to operate on whole disk $disk"
	BOOT_PART="$EFI_PART"
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
	[ "$UEFI_ESP_MIB" -ge 128 ] || die "UEFI_ESP_MIB=$UEFI_ESP_MIB too small (need >= 128 MiB)"
	local esp_end="$((1 + UEFI_ESP_MIB))MiB"
	parted -s "$disk" \
		mktable gpt \
		mkpart lazyos_efi fat32 1MiB "$esp_end" \
		set 1 esp on \
		mkpart lazyos_root ext4 "$esp_end" 100%
	_uefi_wait_parts "$disk"
	_uefi_parts "$disk"
}

boot_layout_mount() {
	local disk="$1" mnt="$2"
	_uefi_parts "$disk"
	log "Formatting $EFI_PART (vfat, label LAZYOS_EFI)"
	mkfs.vfat -F 32 -n LAZYOS_EFI "$EFI_PART" >/dev/null
	BOOT_UUID="$(blkid -s UUID -o value "$EFI_PART")"
	log "Formatting $ROOT_PART (ext4, label lazyos_root)"
	mkfs.ext4 -F -q -L lazyos_root "$ROOT_PART" >/dev/null
	ROOT_UUID="$(blkid -s UUID -o value "$ROOT_PART")"
	[ -n "$BOOT_UUID" ] && [ -n "$ROOT_UUID" ] || die "could not read UEFI partition UUIDs on $disk"

	mkdir -p "$mnt"
	mount "$ROOT_PART" "$mnt"
	mkdir -p "$mnt/boot/efi"
	mount "$EFI_PART" "$mnt/boot/efi"
}

boot_layout_umount() {
	local mnt="$1"
	mountpoint -q "$mnt/boot/efi" && umount "$mnt/boot/efi" || true
	mountpoint -q "$mnt" && umount "$mnt" || true
}

boot_write_fstab() {
	local mnt="$1"
	cat >"$mnt/etc/fstab" <<EOF
UUID=$ROOT_UUID	/	ext4	defaults	0 1
UUID=$BOOT_UUID	/boot/efi	vfat	umask=0077	0 2
EOF
}

# Populate systemd-boot / EFI fallback inside <rootfs>/boot/efi.
boot_install() {
	local rootfs="$1" _target="${2:-}" cmdline_extra="${3:-}"
	local esp="$rootfs/boot/efi"
	local vmlinuz initrd cmdline rel dtb_rel=""

	vmlinuz="$(ls -1 "$rootfs/boot"/vmlinuz-* 2>/dev/null | sort -V | tail -n1)"
	[ -f "$vmlinuz" ] || die "no vmlinuz-* in $rootfs/boot"
	rel="$(basename "$vmlinuz")"
	rel="${rel#vmlinuz-}"
	initrd="$rootfs/boot/initrd.img-$rel"
	[ -f "$initrd" ] || die "no initrd.img-$rel in $rootfs/boot"

	cmdline="$(_boot_build_cmdline "$rootfs" "$cmdline_extra")"

	mkdir -p "$esp/lazyos" "$esp/loader/entries" "$esp/EFI/BOOT"
	cp "$vmlinuz" "$esp/lazyos/vmlinuz-$rel"
	cp "$initrd" "$esp/lazyos/initrd.img-$rel"

	if [ -n "${deviceinfo_dtb:-}" ] && [ -d "$rootfs/boot/dtbs" ]; then
		local dtb_match
		dtb_match="$(find "$rootfs/boot/dtbs" -type f -path "$rootfs/boot/dtbs/$deviceinfo_dtb" 2>/dev/null | head -n1 || true)"
		if [ -n "$dtb_match" ]; then
			dtb_rel="${dtb_match#"$rootfs/boot/dtbs/"}"
			mkdir -p "$esp/lazyos/dtbs/$(dirname "$dtb_rel")"
			cp "$dtb_match" "$esp/lazyos/dtbs/$dtb_rel"
		fi
	fi

	cat >"$esp/loader/loader.conf" <<'EOF'
default lazyos.conf
timeout 1
console-mode max
EOF
	{
		printf 'title   LazyOS (%s)\n' "$rel"
		printf 'linux   /lazyos/vmlinuz-%s\n' "$rel"
		printf 'initrd  /lazyos/initrd.img-%s\n' "$rel"
		[ -n "$dtb_rel" ] && printf 'devicetree /lazyos/dtbs/%s\n' "$dtb_rel"
		printf 'options %s\n' "$cmdline"
	} >"$esp/loader/entries/lazyos.conf"

	local efi_stub
	for efi_stub in \
		"$rootfs/usr/lib/systemd/boot/efi/systemd-bootaa64.efi" \
		"$rootfs/usr/lib/systemd/boot/efi/systemd-bootx64.efi"; do
		if [ -f "$efi_stub" ]; then
			local dest_name="BOOTAA64.EFI"
			case "$efi_stub" in *x64.efi) dest_name="BOOTX64.EFI" ;; esac
			cp "$efi_stub" "$esp/EFI/BOOT/$dest_name"
			mkdir -p "$esp/EFI/systemd"
			cp "$efi_stub" "$esp/EFI/systemd/$(basename "$efi_stub")"
			break
		fi
	done
	log "UEFI boot entry written ($esp/loader/entries/lazyos.conf)"
}

boot_update_running() {
	local root_uuid extra=""
	root_uuid="$(findmnt -n -o UUID / 2>/dev/null || true)"
	[ -n "$root_uuid" ] && extra="root=UUID=$root_uuid rootwait rw"
	boot_install / / "$extra"
}
