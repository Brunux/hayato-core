#!/bin/bash
# Common environment, paths, sub-project discovery, and helpers for hayato-core scripts.
# Sourced by every script; does not execute anything directly.

[ -n "${_LIB_SH_LOADED:-}" ] && return 0
_LIB_SH_LOADED=1

# Logging helpers
log()  { printf '\033[1;34m[hayato]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }
need_root() { [ "$(id -u)" -eq 0 ] || die "this command must run as root (use sudo)"; }

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${CORE_DIR:-}" ]; then
	if [ -d "$_LIB_DIR/boot" ]; then
		CORE_DIR="$_LIB_DIR"
	else
		CORE_DIR="$(cd "$_LIB_DIR/.." && pwd)"
	fi
fi
if [ -d "$CORE_DIR/scripts" ]; then
	CORE_SCRIPTS_DIR="$CORE_DIR/scripts"
else
	CORE_SCRIPTS_DIR="$CORE_DIR"
fi
_PARENT_DIR="$(cd "$CORE_DIR/.." && pwd)"

if [ -n "${HAYATO_ROOT_DIR:-}" ]; then
	REPO_DIR="$HAYATO_ROOT_DIR"
elif [ -f "$_PARENT_DIR/.gitmodules" ] || { [ -d "$_PARENT_DIR/desktop" ] && [ -d "$_PARENT_DIR/devices" ]; }; then
	REPO_DIR="$_PARENT_DIR"
else
	REPO_DIR="$CORE_DIR"
fi

_find_subrepo() {
	local explicit="$1" umb="$2" sib="$3" probe="$4" d
	for d in "$explicit" "$REPO_DIR/$umb" "$_PARENT_DIR/$umb" "$_PARENT_DIR/$sib" "$CORE_DIR/$umb"; do
		[ -n "$d" ] && [ -d "$d/$probe" ] && { (cd "$d" && pwd); return 0; }
	done
	return 1
}

DEVICES_REPO="${DEVICES_REPO:-$(_find_subrepo "${HAYATO_DEVICES_DIR:-}" devices hayato-devices devices || true)}"
DESKTOP_REPO="${DESKTOP_REPO:-$(_find_subrepo "${HAYATO_DESKTOP_DIR:-}" desktop hayato-desktop uis || true)}"

# Working paths on the build host.
# Under sudo without -E, HOME becomes /root; keep BUILD_ROOT tied to SUDO_USER's home.
if [ -n "${SUDO_USER:-}" ]; then
	_invoking_home="$(getent passwd "$SUDO_USER" | cut -d: -f6 || echo "/home/$SUDO_USER")"
else
	_invoking_home="$HOME"
fi
BUILD_ROOT="${BUILD_ROOT:-${_invoking_home:-/root}/.cache/debian-aarch64}"
WORK_DIR="$BUILD_ROOT/work"
SRC_DIR="$BUILD_ROOT/src"
mkdir -p "$WORK_DIR" "$SRC_DIR" 2>/dev/null || true

PACKAGES_DIR="$CORE_DIR/packages"
DEVICES_DIR="${DEVICES_DIR:-${DEVICES_REPO:+$DEVICES_REPO/devices}}"
KERNELS_DIR="${KERNELS_DIR:-${DEVICES_REPO:+$DEVICES_REPO/kernels}}"
UIS_DIR="${UIS_DIR:-${DESKTOP_REPO:+$DESKTOP_REPO/uis}}"
UI="${UI:-sway}"
UI_DIR="${UIS_DIR:+$UIS_DIR/$UI}"
WIFI_DIR="${WIFI_DIR:-$BUILD_ROOT/wifi}"

# Device selection (skips _template when discovering boards).
if [ -n "${DEVICES_DIR:-}" ] && [ -d "$DEVICES_DIR" ]; then
	if [ -z "${DEVICE:-}" ]; then
		if [ -f /etc/hayato/device ] && [ -d "$DEVICES_DIR/$(tr -d ' \t\r\n' </etc/hayato/device)" ]; then
			DEVICE="$(tr -d ' \t\r\n' </etc/hayato/device)"
		elif [ -d "$DEVICES_DIR/google-asurada" ]; then
			DEVICE="google-asurada"
		else
			DEVICE="$(find "$DEVICES_DIR" -mindepth 1 -maxdepth 1 -type d ! -name '_template' -exec basename {} \; | sort | head -n1)"
		fi
	fi
	[ -n "${DEVICE:-}" ] || die "no device selected or found in $DEVICES_DIR"
	case "$DEVICE" in
		*[!a-zA-Z0-9_-]*) die "invalid device name '$DEVICE'" ;;
	esac
	DEVICE_DIR="$DEVICES_DIR/$DEVICE"
	[ -d "$DEVICE_DIR" ] || die "unknown device '$DEVICE' (see $DEVICES_DIR)"
	# shellcheck disable=SC1090
	. "$DEVICE_DIR/deviceinfo"
elif [ -f /etc/hayato/deviceinfo ]; then
	DEVICE="${DEVICE:-$(tr -d ' \t\r\n' </etc/hayato/device 2>/dev/null || echo runtime)}"
	DEVICE_DIR="/etc/hayato"
	# shellcheck disable=SC1091
	. /etc/hayato/deviceinfo
elif [ "${HAYATO_ALLOW_NO_DEVICE:-0}" = 1 ]; then
	DEVICE="${DEVICE:-generic}"
	DEVICE_DIR=""
else
	die "no hayato-devices checkout or /etc/hayato/deviceinfo found (set HAYATO_DEVICES_DIR)"
fi

BOOT_TYPE="${deviceinfo_boot_type:-depthcharge}"
case "$BOOT_TYPE" in
	depthcharge|uefi|extlinux) ;;
	*) die "unsupported deviceinfo_boot_type='$BOOT_TYPE'" ;;
esac
BOOT_BACKEND="$CORE_DIR/boot/${BOOT_TYPE}.sh"
[ -f "$BOOT_BACKEND" ] || die "unsupported deviceinfo_boot_type='$BOOT_TYPE' (missing $BOOT_BACKEND)"

ARCH="${deviceinfo_arch:-aarch64}"
DEVICE_ARCH="$ARCH"
case "$ARCH" in
	aarch64) KERNEL_ARCH="arm64" ;;
	x86_64)  KERNEL_ARCH="x86_64" ;;
	*)       die "unsupported architecture: $ARCH" ;;
esac

if [ -n "${DEVICE_DIR:-}" ] && [ -r "$DEVICE_DIR/kernel-cmdline.conf" ]; then
	KERNEL_CMDLINE="${KERNEL_CMDLINE_OVERRIDE:-$(tr '\n' ' ' <"$DEVICE_DIR/kernel-cmdline.conf" 2>/dev/null || true)}"
else
	KERNEL_CMDLINE="${KERNEL_CMDLINE_OVERRIDE:-quiet loglevel=2 transparent_hugepage=madvise}"
fi
INITFS_MODULES="${INITFS_MODULES_OVERRIDE:-$([ -n "${DEVICE_DIR:-}" ] && grep -v '^[[:space:]]*#' "$DEVICE_DIR/modules-initfs" 2>/dev/null | tr '\n' ' ' || true)}"

# Kernel metadata (supports both monolithic config.<arch> and arm64-mainline base.config,
# and degrades cleanly on a booted device without kernel sources).
if [ -n "${DEVICE_DIR:-}" ] && [ -f "$DEVICE_DIR/kernel" ] && [ -n "${KERNELS_DIR:-}" ]; then
	KERNEL_FLAVOR="$(tr -d ' \t\r\n' <"$DEVICE_DIR/kernel")"
	KERNEL_DIR="$KERNELS_DIR/$KERNEL_FLAVOR"
	[ -d "$KERNEL_DIR" ] || die "kernel flavor '$KERNEL_FLAVOR' (device '$DEVICE') not found in $KERNELS_DIR"
	KERNEL_VERSION="$(tr -d ' \t\r\n' <"$KERNEL_DIR/version")"
	KERNEL_PATCH_DIR="$KERNEL_DIR/patches"
	if [ -f "$KERNEL_DIR/package" ]; then
		KERNEL_SOURCE_TYPE="debian-pkg"
		KERNEL_PACKAGE="$(tr -d ' \t\r\n' <"$KERNEL_DIR/package")"
		KERNEL_TARBALL=""
		KERNEL_URL=""
		KERNEL_SRC=""
		KERNEL_CONFIG=""
		KERNEL_BASE_CONFIG=""
		KERNEL_LOCALVERSION=""
		KERNEL_RELEASE="${KERNEL_RELEASE:-debian-pkg}"
	else
		KERNEL_SOURCE_TYPE="source"
		KERNEL_PACKAGE=""
		KERNEL_TARBALL="linux-${KERNEL_VERSION}.tar.xz"
		KERNEL_URL="https://cdn.kernel.org/pub/linux/kernel/v${KERNEL_VERSION%%.*}.x/${KERNEL_TARBALL}"
		KERNEL_SRC="$SRC_DIR/linux-$KERNEL_VERSION"
		KERNEL_CONFIG="$KERNEL_DIR/config.$ARCH"
		KERNEL_BASE_CONFIG="$KERNEL_DIR/base.config"
		if [ -f "$KERNEL_CONFIG" ]; then
			KERNEL_LOCALVERSION="$(sed -n 's/^CONFIG_LOCALVERSION="\(.*\)"$/\1/p' "$KERNEL_CONFIG" | head -n1)"
		elif [ -f "$KERNEL_BASE_CONFIG" ]; then
			KERNEL_LOCALVERSION="$(sed -n 's/^CONFIG_LOCALVERSION="\(.*\)"$/\1/p' "$KERNEL_BASE_CONFIG" | head -n1)"
		else
			KERNEL_LOCALVERSION=""
		fi
		KERNEL_RELEASE="${KERNEL_RELEASE:-${KERNEL_VERSION}${KERNEL_LOCALVERSION}}"
	fi
else
	KERNEL_FLAVOR="${KERNEL_FLAVOR:-runtime}"
	KERNEL_SOURCE_TYPE="${KERNEL_SOURCE_TYPE:-source}"
	KERNEL_PACKAGE=""
	KERNEL_DIR=""
	KERNEL_PATCH_DIR=""
	KERNEL_TARBALL=""
	KERNEL_URL=""
	KERNEL_SRC=""
	KERNEL_CONFIG=""
	KERNEL_BASE_CONFIG=""
	KERNEL_RELEASE="${KERNEL_RELEASE:-$(uname -r)}"
	KERNEL_VERSION="${KERNEL_VERSION:-${KERNEL_RELEASE%%-*}}"
	KERNEL_LOCALVERSION="-${KERNEL_RELEASE#*-}"
fi

# Resolve actual installed kernel release inside <rootfs> for debian-pkg kernels.
resolve_kernel_release() {
	local rootfs="${1:-/}"
	if [ "${KERNEL_SOURCE_TYPE:-source}" = "debian-pkg" ] || [ "${KERNEL_RELEASE:-}" = "debian-pkg" ]; then
		local resolved
		resolved="$(find "$rootfs/lib/modules" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null | sort -V | tail -n1)"
		[ -n "$resolved" ] || die "no installed kernel modules found in $rootfs/lib/modules"
		KERNEL_RELEASE="$resolved"
		export KERNEL_RELEASE
	fi
}

# Desktop / UI build variables (optional when running core standalone or live on device).
COMPOSITOR="${COMPOSITOR:-swayfx}"
WORKSTYLE="workstyle"
OPENCODE="opencode"
HAYATO_STAGE="$WORK_DIR/hayato-stage"

if [ -n "${DESKTOP_REPO:-}" ] && [ -d "$DESKTOP_REPO" ]; then
	COMPOSITOR_DIR="$DESKTOP_REPO/compositors/$COMPOSITOR"
	if [ -d "$COMPOSITOR_DIR" ]; then
		COMPOSITOR_VERSION="$(tr -d ' \t\r\n' <"$COMPOSITOR_DIR/version")"
		SCENEFX_VERSION="$(tr -d ' \t\r\n' <"$COMPOSITOR_DIR/scenefx-version")"
		COMPOSITOR_STAGE="$WORK_DIR/${COMPOSITOR}-stage"
		COMPOSITOR_SRC="$SRC_DIR/$COMPOSITOR-$COMPOSITOR_VERSION"
		SCENEFX_SRC="$SRC_DIR/scenefx-$SCENEFX_VERSION"
		COMPOSITOR_TARBALL="$COMPOSITOR-$COMPOSITOR_VERSION.tar.gz"
		SCENEFX_TARBALL="scenefx-$SCENEFX_VERSION.tar.gz"
		COMPOSITOR_URL="https://github.com/WillPower3309/$COMPOSITOR/archive/refs/tags/$COMPOSITOR_VERSION.tar.gz"
		SCENEFX_URL="https://github.com/wlrfx/scenefx/archive/refs/tags/$SCENEFX_VERSION.tar.gz"
	fi
	WORKSTYLE_DIR="$DESKTOP_REPO/tools/$WORKSTYLE"
	if [ -d "$WORKSTYLE_DIR" ]; then
		WORKSTYLE_VERSION="$(tr -d ' \t\r\n' <"$WORKSTYLE_DIR/version")"
		WORKSTYLE_STAGE="$WORK_DIR/$WORKSTYLE-stage"
		WORKSTYLE_SRC="$SRC_DIR/$WORKSTYLE-$WORKSTYLE_VERSION"
		WORKSTYLE_TARBALL="$WORKSTYLE-$WORKSTYLE_VERSION.crate"
		WORKSTYLE_URL="https://static.crates.io/crates/$WORKSTYLE/$WORKSTYLE_TARBALL"
	fi
	OPENCODE_DIR="$DESKTOP_REPO/tools/$OPENCODE"
	if [ -d "$OPENCODE_DIR" ]; then
		OPENCODE_VERSION="$(tr -d ' \t\r\n' <"$OPENCODE_DIR/version")"
		OPENCODE_TARBALL="$OPENCODE-cli-linux-arm64-$OPENCODE_VERSION.tgz"
		OPENCODE_URL="https://registry.npmjs.org/@opencode/cli-linux-arm64/-/cli-linux-arm64-$OPENCODE_VERSION.tgz"
	fi
	EDITXR="editxr"
	EDITXR_DIR="$DESKTOP_REPO/tools/$EDITXR"
	if [ -d "$EDITXR_DIR" ]; then
		EDITXR_VERSION="$(tr -d ' \t\r\n' <"$EDITXR_DIR/version")"
		EDITXR_TARBALL="$EDITXR-v$EDITXR_VERSION-linux-aarch64.tar.gz"
		EDITXR_URL="https://github.com/pixdeo/$EDITXR/releases/download/v$EDITXR_VERSION/$EDITXR_TARBALL"
	fi
else
	COMPOSITOR_DIR=""
	COMPOSITOR_STAGE="$WORK_DIR/${COMPOSITOR}-stage"
	WORKSTYLE_DIR=""
	WORKSTYLE_STAGE="$WORK_DIR/$WORKSTYLE-stage"
	OPENCODE_DIR=""
	EDITXR_DIR=""
fi

require_compositor() {
	[ -n "${COMPOSITOR_DIR:-}" ] && [ -d "$COMPOSITOR_DIR" ] ||
		die "compositor '$COMPOSITOR' not found (set HAYATO_DESKTOP_DIR or place hayato-desktop alongside hayato-core)"
}

require_desktop() {
	[ -n "${DESKTOP_REPO:-}" ] && [ -d "$DESKTOP_REPO" ] ||
		die "hayato-desktop checkout not found (set HAYATO_DESKTOP_DIR or place hayato-desktop alongside hayato-core)"
}

require_devices() {
	[ -n "${DEVICES_REPO:-}" ] && [ -d "$DEVICES_REPO" ] ||
		die "hayato-devices checkout not found (set HAYATO_DEVICES_DIR or place hayato-devices alongside hayato-core)"
}

build_deb() {
	local outdir="$1" tree="$2" name="$3" version="$4" depends="$5" desc="$6" extra="${7:-}"
	local arch size
	arch="$(dpkg --print-architecture)"
	size="$(du -sk --exclude=DEBIAN "$tree" | cut -f1)"
	mkdir -p "$tree/DEBIAN" "$outdir"
	{
		printf 'Package: %s\n' "$name"
		printf 'Version: %s\n' "$version"
		printf 'Architecture: %s\n' "$arch"
		printf 'Maintainer: %s\n' "Hayato builder <builder@localhost>"
		printf 'Installed-Size: %s\n' "$size"
		if [ -n "$depends" ]; then printf 'Depends: %s\n' "$depends"; fi
		printf 'Section: x11\n'
		printf 'Priority: optional\n'
		if [ -n "$extra" ]; then printf '%s\n' "$extra"; fi
		printf 'Description: %s\n' "$desc"
	} >"$tree/DEBIAN/control"
	dpkg-deb --root-owner-group --build "$tree" "$outdir/${name}_${version}_${arch}.deb" >/dev/null
	log "Packaged ${name}_${version}_${arch}.deb"
}

# deb_depends <file>...: the packages that own the shared libraries the given
# binaries need, as a comma separated list. dpkg-shlibdeps does this from a
# debian/ directory; this build has none, so each DT_NEEDED name is resolved to
# the real file by the host's ldconfig cache and that exact path is asked of
# dpkg. Asking dpkg for the bare soname is not the same thing: `libc.so.6` also
# matches the linker script of that name in libc6-dev, and a -dev package would
# then end up on the target.
deb_depends() {
	local list="" soname path pkg f
	# /sbin is not on a normal user's PATH, and this runs unprivileged.
	local ldconfig
	ldconfig="$(command -v ldconfig || printf /sbin/ldconfig)"
	for f in "$@"; do
		for soname in $(readelf -d "$f" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p'); do
			path="$("$ldconfig" -p | awk -v s="$soname" '$1 == s { print $NF; exit }')"
			if [ -z "$path" ]; then
				# A library built by the same script (libscenefx) is not in the
				# host's cache yet; anything else means the build host is missing
				# a library the binary will need at runtime.
				case "$soname" in libscenefx-*) ;; *)
					warn "no library named $soname on this host (needed by $(basename "$f"))"
					;;
				esac
				continue
			fi
			pkg="$(dpkg -S "$path" 2>/dev/null | head -n1 | cut -d: -f1)"
			if [ -z "$pkg" ]; then
				warn "$path (needed by $(basename "$f")) belongs to no package"
				continue
			fi
			# Keep the list comma separated without spaces while deduplicating
			# (a pattern cannot look for ", pkg," and ",pkg," at once).
			case ",$list," in
			*",$pkg,"*) ;;
			*) list="${list:+$list,}$pkg" ;;
			esac
		done
	done
	printf '%s\n' "$list" | sed 's/,/, /g'
}

# ---------------------------------------------------------------------------
# Boot chain (depthcharge / ChromeOS GPT)
# ---------------------------------------------------------------------------
DEPTHCHARGE_BOARD="${deviceinfo_depthcharge_board:-}"
DEPTHCHARGE_COMPRESSION="${deviceinfo_depthcharge_compression:-lz4}"

# Bootloader geometry defaults
KPART_START_SECTORS="${deviceinfo_cgpt_kpart_start:-8192}"
KPART_SIZE_SECTORS="${deviceinfo_cgpt_kpart_size:-262144}"   # 128 MiB
KPART_PATH="${deviceinfo_cgpt_kpart:-/boot/vmlinuz.kpart}"
DEPTHCHARGE_ARCH="${deviceinfo_depthcharge_arch:-arm64}"
DTB_GLOB="${deviceinfo_dtb:-}"
BOOT_SIZE_MIB="${BOOT_SIZE_MIB:-${deviceinfo_boot_size_mib:-512}}"
BOOT_FS="${BOOT_FS:-${deviceinfo_boot_filesystem:-ext2}}"
IMAGE_SIZE_MIB="${IMAGE_SIZE_MIB:-${deviceinfo_image_size_mib:-6144}}"

# Debian debootstrap / image settings
DEBIAN_SUITE="${DEBIAN_SUITE:-forky}"
case "$ARCH" in
	aarch64) _debian_arch="arm64" ;;
	x86_64)  _debian_arch="amd64" ;;
	*)       _debian_arch="$ARCH" ;;
esac
DEBIAN_ARCH="${DEBIAN_ARCH:-$_debian_arch}"
DEBIAN_MIRROR="${DEBIAN_MIRROR:-http://deb.debian.org/debian}"
DEBIAN_COMPONENTS="${DEBIAN_COMPONENTS:-main contrib non-free non-free-firmware}"
ROOTFS="${ROOTFS:-$WORK_DIR/rootfs-$DEVICE-$UI}"
LOCALE="${LOCALE:-en_US.UTF-8}"
TIMEZONE="${TIMEZONE:-America/Mexico_City}"

KERNEL_STAGE="${KERNEL_STAGE:-$WORK_DIR/kernel-stage-$KERNEL_FLAVOR}"
KPART="${KPART:-$WORK_DIR/$DEVICE.vmlinuz.kpart}"

_boot_build_cmdline() {
	local rootfs="${1:-/}" extra="${2:-}" base=""
	if [ -r "$rootfs/etc/hayato/kernel-cmdline.conf" ]; then
		base="$(grep -v '^[[:space:]]*#' "$rootfs/etc/hayato/kernel-cmdline.conf" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g;s/^ //;s/ $//')"
	elif [ -n "${KERNEL_CMDLINE:-}" ]; then
		base="$(printf '%s' "$KERNEL_CMDLINE" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g;s/^ //;s/ $//')"
	fi
	printf '%s\n' "${base}${extra:+ $extra}" | sed 's/^ //;s/ $//'
}

# Sync <src_rootfs> onto <dst_mnt> (mounted by boot_layout_mount) in two passes
# so cross-filesystem hard links (e.g. Debian kernel /boot <-> /usr/lib/modules)
# never trigger EXDEV under `rsync -H`, and a mounted FAT32 ESP at /boot/efi is untouched.
sync_rootfs_to_mount() {
	local src="${1%/}" dst="${2%/}" excl_file="${3:-}"
	local _stale_mounts
	_stale_mounts="$(findmnt -rn -o TARGET 2>/dev/null | grep -F "$src/" || true)"
	[ -z "$_stale_mounts" ] ||
		die "something is mounted under $src ($_stale_mounts); unmount it first"

	local -a root_args=(-aHAX --delete --exclude=/boot)
	[ -n "$excl_file" ] && root_args+=(--exclude-from="$excl_file")
	rsync "${root_args[@]}" "$src"/ "$dst"/

	mkdir -p "$dst/boot"
	rsync -aHAX --delete --exclude=/efi "$src/boot"/ "$dst/boot"/
}

export CORE_DIR CORE_SCRIPTS_DIR REPO_DIR DEVICES_REPO DESKTOP_REPO
export ARCH DEVICE_ARCH BUILD_ROOT WORK_DIR SRC_DIR ROOTFS
export DEVICE DEVICE_DIR DEVICES_DIR KERNELS_DIR KERNEL_DIR
export KERNEL_FLAVOR KERNEL_SOURCE_TYPE KERNEL_PACKAGE KERNEL_VERSION KERNEL_RELEASE KERNEL_STAGE KERNEL_ARCH KPART
export BOOT_TYPE BOOT_BACKEND BOOT_SIZE_MIB BOOT_FS IMAGE_SIZE_MIB DTB_GLOB
export UI UIS_DIR UI_DIR PACKAGES_DIR WIFI_DIR
export COMPOSITOR COMPOSITOR_DIR COMPOSITOR_VERSION COMPOSITOR_STAGE
export WORKSTYLE WORKSTYLE_DIR WORKSTYLE_VERSION WORKSTYLE_STAGE
export HAYATO_STAGE OPENCODE OPENCODE_DIR OPENCODE_VERSION OPENCODE_TARBALL OPENCODE_URL
export EDITXR EDITXR_DIR EDITXR_VERSION EDITXR_TARBALL EDITXR_URL
export DEBIAN_SUITE DEBIAN_ARCH DEBIAN_MIRROR DEBIAN_COMPONENTS LOCALE TIMEZONE
