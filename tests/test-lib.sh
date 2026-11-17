#!/bin/bash
# Unit tests for scripts/lib.sh: device discovery, kernel metadata and the
# boot command line. Everything runs against throwaway mock trees so the
# maintainer's checkout and build root are never touched.
set -u
cd "$(dirname "$0")/.." || exit 1
. tests/harness.sh

ROOT="$(pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# make_device <repo-root> <device> <boot-type> <arch>
# A minimal devices repository with one source-built kernel flavor.
make_device() {
	local repo="$1" dev="$2" boot="$3" arch="$4"
	mkdir -p "$repo/devices/$dev" "$repo/kernels/arm64-mainline"
	printf 'arm64-mainline\n' >"$repo/devices/$dev/kernel"
	printf 'deviceinfo_codename="%s"\ndeviceinfo_arch="%s"\ndeviceinfo_boot_type="%s"\n' \
		"$dev" "$arch" "$boot" >"$repo/devices/$dev/deviceinfo"
	printf '6.12.28\n' >"$repo/kernels/arm64-mainline/version"
	printf 'CONFIG_LOCALVERSION="-lazyos"\nCONFIG_PREEMPT=y\n' \
		>"$repo/kernels/arm64-mainline/base.config"
}

# --- boot type, architecture and kernel metadata --------------------------
REPO_A="$TMP/repo-a"
make_device "$REPO_A" mock-depth depthcharge aarch64
printf 'quiet   loglevel=2\nroot=PARTUUID=abcd-ef01\n' \
	>"$REPO_A/devices/mock-depth/kernel-cmdline.conf"
printf '# early modules\nnvme\nphy-rockchip\n' \
	>"$REPO_A/devices/mock-depth/modules-initfs"
printf 'deviceinfo_boot_size_mib="768"\ndeviceinfo_boot_filesystem="vfat"\n' \
	>>"$REPO_A/devices/mock-depth/deviceinfo"

(
	export BUILD_ROOT="$TMP/build-a"
	export LAZYOS_DEVICES_DIR="$REPO_A"
	export DEVICE=mock-depth
	# shellcheck disable=SC1091
	. "$ROOT/scripts/lib.sh"

	assert_eq "depthcharge" "$BOOT_TYPE" "boot type comes from deviceinfo"
	assert_eq "$ROOT/boot/depthcharge.sh" "$BOOT_BACKEND" "boot backend follows the boot type"
	assert_eq "aarch64" "$ARCH" "device architecture is exported"
	assert_eq "arm64" "$KERNEL_ARCH" "aarch64 maps to the arm64 kernel architecture"
	assert_eq "source" "$KERNEL_SOURCE_TYPE" "a base.config kernel is source-built"
	assert_eq "arm64-mainline" "$KERNEL_FLAVOR" "kernel flavor comes from the device"
	assert_eq "6.12.28-lazyos" "$KERNEL_RELEASE" "release is version plus CONFIG_LOCALVERSION"
	assert_eq "768" "$BOOT_SIZE_MIB" "boot size comes from deviceinfo"
	assert_eq "vfat" "$BOOT_FS" "boot filesystem comes from deviceinfo"
	assert_contains "$KERNEL_CMDLINE" "quiet" "device kernel cmdline is read"
	assert_contains "$KERNEL_CMDLINE" "root=PARTUUID=abcd-ef01" "cmdline keeps the root argument"
	assert_eq "nvme phy-rockchip " "$INITFS_MODULES" "initfs modules drop comments and join lines"
)

# --- unsupported architecture is refused loudly ---------------------------
REPO_BAD="$TMP/repo-bad"
make_device "$REPO_BAD" mock-bad uefi mips
out="$(
	(
		export BUILD_ROOT="$TMP/build-bad"
		export LAZYOS_DEVICES_DIR="$REPO_BAD"
		export DEVICE=mock-bad
		# shellcheck disable=SC1091
		. "$ROOT/scripts/lib.sh"
	) 2>&1
)"
status=$?
assert_eq "1" "$status" "an unsupported architecture stops the build"
assert_contains "$out" "unsupported architecture: mips" "the refusal names the architecture"

# --- device discovery skips _template and sorts ----------------------------
REPO_PICK="$TMP/repo-pick"
for dev in _template zzz aaa; do
	make_device "$REPO_PICK" "$dev" extlinux aarch64
done
(
	export BUILD_ROOT="$TMP/build-pick"
	export LAZYOS_DEVICES_DIR="$REPO_PICK"
	unset DEVICE
	# shellcheck disable=SC1091
	. "$ROOT/scripts/lib.sh"
	assert_eq "aaa" "$DEVICE" "without a default board, the first sorted device wins"
	assert_ne "_template" "$DEVICE" "_template is never selected"
)

# --- google-asurada remains the default when present ----------------------
REPO_DEFAULT="$TMP/repo-default"
make_device "$REPO_DEFAULT" aaa extlinux aarch64
make_device "$REPO_DEFAULT" google-asurada depthcharge aarch64
(
	export BUILD_ROOT="$TMP/build-default"
	export LAZYOS_DEVICES_DIR="$REPO_DEFAULT"
	unset DEVICE
	# shellcheck disable=SC1091
	. "$ROOT/scripts/lib.sh"
	assert_eq "google-asurada" "$DEVICE" "google-asurada is preferred over the alphabetical first"
)

# --- packaged Debian kernels resolve the installed release ----------------
REPO_DEB="$TMP/repo-deb"
mkdir -p "$REPO_DEB/devices/mock-deb" "$REPO_DEB/kernels/debian-arm64"
printf 'debian-arm64\n' >"$REPO_DEB/devices/mock-deb/kernel"
printf 'deviceinfo_codename="mock-deb"\ndeviceinfo_arch="aarch64"\ndeviceinfo_boot_type="uefi"\n' \
	>"$REPO_DEB/devices/mock-deb/deviceinfo"
printf '7.2.15\n' >"$REPO_DEB/kernels/debian-arm64/version"
printf 'linux-image-arm64\n' >"$REPO_DEB/kernels/debian-arm64/package"
mkdir -p "$TMP/deb-root/lib/modules/7.2.9+deb14-arm64" \
	"$TMP/deb-root/lib/modules/7.2.15+deb14-arm64" \
	"$TMP/deb-root/lib/modules/7.2.10+deb14-arm64"
(
	export BUILD_ROOT="$TMP/build-deb"
	export LAZYOS_DEVICES_DIR="$REPO_DEB"
	export DEVICE=mock-deb
	# shellcheck disable=SC1091
	. "$ROOT/scripts/lib.sh"

	assert_eq "debian-pkg" "$KERNEL_SOURCE_TYPE" "a package marker selects the Debian kernel"
	assert_eq "linux-image-arm64" "$KERNEL_PACKAGE" "the package name is read"
	assert_eq "debian-pkg" "$KERNEL_RELEASE" "the release is deferred until the rootfs exists"
	resolve_kernel_release "$TMP/deb-root"
	assert_eq "7.2.15+deb14-arm64" "$KERNEL_RELEASE" "sort -V picks the highest installed kernel"
)

# --- resolve_kernel_release refuses an empty /lib/modules -----------------
(
	export BUILD_ROOT="$TMP/build-empty"
	export LAZYOS_DEVICES_DIR="$REPO_DEB"
	export DEVICE=mock-deb
	# shellcheck disable=SC1091
	. "$ROOT/scripts/lib.sh"
	mkdir -p "$TMP/empty-root/lib/modules"
	resolve_kernel_release "$TMP/empty-root"
) >/dev/null 2>&1
assert_eq "1" "$?" "resolve_kernel_release fails when no kernel is installed"

# --- _boot_build_cmdline strips comments and normalises whitespace --------
CMDLINE_ROOT="$TMP/cmdline-root"
mkdir -p "$CMDLINE_ROOT/etc/lazyos"
printf '# host-specific comment\nquiet   loglevel=2\n  root=PARTUUID=1111\n' \
	>"$CMDLINE_ROOT/etc/lazyos/kernel-cmdline.conf"
(
	export BUILD_ROOT="$TMP/build-cmdline"
	export LAZYOS_DEVICES_DIR="$REPO_A"
	export DEVICE=mock-depth
	# shellcheck disable=SC1091
	. "$ROOT/scripts/lib.sh"
	assert_eq "quiet loglevel=2 root=PARTUUID=1111 rw" \
		"$(_boot_build_cmdline "$CMDLINE_ROOT" rw)" \
		"a rootfs cmdline drops comments and extra spaces"
	assert_eq "quiet loglevel=2 root=PARTUUID=abcd-ef01 extra" \
		"$(_boot_build_cmdline "$TMP/no-such-rootfs" extra)" \
		"without a rootfs the device cmdline is the base"
)

finish
