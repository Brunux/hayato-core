#!/bin/bash
# Unit tests for scripts/lib-cgpt.sh: the ChromeOS GPT geometry, partition
# resolution and /etc/fstab. Block devices and cgpt/parted are shimmed so the
# suite runs anywhere and asserts the arguments the helpers build, which is
# where the boot-breaking mistakes have been.
set -u
cd "$(dirname "$0")/.." || exit 1
. tests/harness.sh

ROOT="$(pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

die() {
	printf '[fail] %s\n' "$*" >&2
	exit 1
}
log() { :; }
warn() { printf '[warn] %s\n' "$*" >&2; }

BOOT_SIZE_MIB=512
BOOT_FS=ext2
KPART_START_SECTORS=8192
KPART_SIZE_SECTORS=262144

# shellcheck disable=SC1091
. "$ROOT/scripts/lib-cgpt.sh"

# --- /etc/fstab is written by UUID with the Debian pass column ------------
FSTAB_MNT="$TMP/fstab"
mkdir -p "$FSTAB_MNT/etc"
ROOT_UUID="1111-2222"
BOOT_UUID="3333-4444"
disk_layout_fstab "$FSTAB_MNT"
expected="UUID=1111-2222	/	ext4	defaults	0 1
UUID=3333-4444	/boot	ext2	nodev,nosuid,noexec	0 2"
assert_eq "$expected" "$(cat "$FSTAB_MNT/etc/fstab")" \
	"fstab mounts root and /boot by UUID with the right options"

# --- kpart_fits refuses an image larger than the partition ----------------
FAKE_PART_BYTES=4096
blockdev() {
	case "$1" in
	--getsize64) printf '%s\n' "$FAKE_PART_BYTES" ;;
	--getsz) printf '%s\n' "${TOTAL_SECTORS:-10000000}" ;;
	*) return 1 ;;
	esac
}
KPART_IMG="$TMP/kpart.img"
printf '0123456789' >"$KPART_IMG"
(
	FAKE_PART_BYTES=4096
	expect_status 0 "a 10-byte kpart fits in a 4 KiB partition" kpart_fits "$KPART_IMG" /dev/fake
	FAKE_PART_BYTES=5
	expect_status 1 "a 10-byte kpart does not fit in a 5-byte partition" kpart_fits "$KPART_IMG" /dev/fake
)

# --- disk_layout_create derives the documented geometry -------------------
CALLS="$TMP/calls.txt"
: >"$CALLS"
dd() { :; }
parted() { printf 'parted %s\n' "$*" >>"$CALLS"; }
cgpt() { printf 'cgpt %s\n' "$*" >>"$CALLS"; }
partprobe() { :; }
partx() { :; }
udevadm() { :; }
sleep() { :; }

(
	TOTAL_SECTORS=10000000
	disk_layout_create /dev/fake
	assert_eq "270336" "$BOOT_START" "boot starts after the 128 MiB kernel partition"
	assert_eq "1048576" "$BOOT_SIZE" "a 512 MiB boot partition is 1048576 sectors"
	assert_eq "1318912" "$ROOT_START" "root starts after /boot"
	assert_eq "8681055" "$ROOT_SIZE" "root ends before the 33-sector backup GPT"
	assert_contains "$(cat "$CALLS")" "cgpt add -i 1 -b 8192 -s 262144 -t kernel -l pmOS_kernel -S 1 -T 5 -P 10 /dev/fake" \
		"the kernel partition carries the pmbootstrap flags"
	assert_contains "$(cat "$CALLS")" "-t efi -l pmOS_boot /dev/fake" \
		"the boot partition is an EFI partition labelled pmOS_boot"
	assert_contains "$(cat "$CALLS")" "-t data -l pmOS_root /dev/fake" \
		"the root partition is a data partition labelled pmOS_root"
	assert_contains "$(cat "$CALLS")" "parted -s /dev/fake mktable gpt" \
		"parted writes the protective MBR and table before cgpt"
)

(
	BOOT_SIZE_MIB=256
	expect_status 1 "a boot partition below 512 MiB is refused" disk_layout_create /dev/fake
)

(
	TOTAL_SECTORS=1000000
	expect_status 1 "a disk too small for a root filesystem is refused" disk_layout_create /dev/fake
)

# --- disk_layout_parts resolves by partition number, not line order -------
lsblk() {
	# lsblk -nro PATH,PARTN DISK | lsblk -nro PARTLABEL PART
	if [ "$2" = "PATH,PARTN" ]; then
		# Deliberately out of order: the kernel may hand out minors as 3 1 2.
		printf '/dev/fake3 3\n/dev/fake1 1\n/dev/fake2 2\n'
	elif [ "$2" = "PARTLABEL" ]; then
		case "$3" in
		/dev/fake1) printf 'pmOS_kernel\n' ;;
		/dev/fake2) printf 'pmOS_boot\n' ;;
		/dev/fake3) printf 'pmOS_root\n' ;;
		esac
	fi
}
(
	disk_layout_parts /dev/fake
	assert_eq "/dev/fake1" "$KPART_PART" "the kernel partition is the one with PARTN=1"
	assert_eq "/dev/fake2" "$BOOT_PART" "the boot partition is the one with PARTN=2"
	assert_eq "/dev/fake3" "$ROOT_PART" "the root partition is the one with PARTN=3"
)

# A label that does not match the number is a wrong resolution, not a warning.
(
	lsblk() {
		if [ "$2" = "PATH,PARTN" ]; then
			printf '/dev/fake1 1\n/dev/fake2 2\n/dev/fake3 3\n'
		elif [ "$2" = "PARTLABEL" ]; then
			case "$3" in
			/dev/fake1) printf 'pmOS_boot\n' ;;
			/dev/fake2) printf 'pmOS_boot\n' ;;
			/dev/fake3) printf 'pmOS_root\n' ;;
			esac
		fi
	}
	expect_status 1 "a partition whose label does not match its number is refused" \
		disk_layout_parts /dev/fake
)

# Resolving the disk itself instead of a partition is refused before any write.
(
	lsblk() {
		if [ "$2" = "PATH,PARTN" ]; then
			printf '/dev/fake 1\n/dev/fake2 2\n/dev/fake3 3\n'
		fi
	}
	expect_status 1 "the whole disk is never accepted as a partition" \
		disk_layout_parts /dev/fake
)

finish
