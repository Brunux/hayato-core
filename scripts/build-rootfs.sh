#!/bin/bash
# Build a Debian rootfs for the selected device using debootstrap.
#
# Device: env DEVICE (default: the only one under devices/).
# Requires root (re-execs itself through sudo).
set -euo pipefail
# Debian's debootstrap and every `install -d` below inherit the caller's umask.
# A desktop user's 0002 would make /, /etc and /usr 0775 in the image, and
# systemd-tmpfiles-setup requires the 0755 the FHS names; the build states it
# rather than trusting the shell it runs in.
umask 022
. "$(dirname "$0")/lib.sh"

UI="${UI:-sway}"
require_desktop
[ -d "$UI_DIR" ] || die "unknown UI '$UI' (see $UIS_DIR)"
TARGET_HOSTNAME="${TARGET_HOSTNAME:-hayato}"
USERNAME="${HAYATO_USER:-${USERNAME:-brunux}}"
USERPASS="${USERPASS:-debian}"
# The one source of the version the image reports: /etc/os-release's
# PRETTY_NAME and VERSION_ID come from this file, so a build cannot say 0.2
# while the tag says v0.3.0.
VERSION="$(cat "$CORE_DIR/VERSION" 2>/dev/null || echo 0.0.0)"

if [ "$(id -u)" -ne 0 ]; then
	# Forward every resolved build input: sudo does not preserve the caller's
	# environment, so an override passed to this script (USERNAME, TIMEZONE, …)
	# would otherwise be silently dropped and replaced by the default.
	exec sudo -n \
		BUILD_ROOT="$BUILD_ROOT" WORK_DIR="$WORK_DIR" SRC_DIR="$SRC_DIR" \
		HAYATO_ROOT_DIR="${REPO_DIR:-}" HAYATO_DEVICES_DIR="${DEVICES_REPO:-}" \
		HAYATO_DESKTOP_DIR="${DESKTOP_REPO:-}" \
		DEVICE="$DEVICE" UI="$UI" WIFI_DIR="$WIFI_DIR" \
		LOCALE="$LOCALE" TIMEZONE="$TIMEZONE" \
		TARGET_HOSTNAME="$TARGET_HOSTNAME" USERNAME="$USERNAME" USERPASS="$USERPASS" \
		VERSION="$VERSION" \
		DEBIAN_SUITE="$DEBIAN_SUITE" DEBIAN_MIRROR="$DEBIAN_MIRROR" \
		DEBIAN_COMPONENTS="$DEBIAN_COMPONENTS" ROOTFS="$ROOTFS" \
		"$(readlink -f "$0")" "$@"
fi

# Anything mounted *under* the tree has to go before the `rm -rf` below, and the
# check is not cosmetic: a rootfs left with the host's /dev bind-mounted (the
# headless test harness does that, and a killed run leaves it behind) makes
# `rm -rf "$ROOTFS"` walk into the *host's* devtmpfs and delete its device nodes.
# That happened once here: null, zero, the disks and the DRM nodes disappeared
# and had to be rebuilt with mknod + `udevadm trigger`.  Unmount everything,
# newest first, and refuse to continue if anything survives.
cleanup_mounts() {
	_left="$(findmnt -rn -o TARGET 2>/dev/null |
		awk -v r="$ROOTFS" 'index($0, r "/") == 1' | sort -r)"
	[ -n "$_left" ] || return 0
	printf '%s\n' "$_left" | while read -r _m; do
		umount -lf "$_m" 2>/dev/null || true
	done
}
trap cleanup_mounts EXIT

log "Device : $DEVICE ($DEVICE_ARCH)"
log "Kernel : $KERNEL_FLAVOR $KERNEL_RELEASE"
log "Rootfs : $ROOTFS"

log "debootstrap $DEBIAN_SUITE/$DEBIAN_ARCH"
cleanup_mounts
_left="$(findmnt -rn -o TARGET 2>/dev/null |
	awk -v r="$ROOTFS" 'index($0, r "/") == 1')"
[ -z "$_left" ] ||
	die "still mounted under $ROOTFS, refusing to wipe it:\n$_left"
rm -rf "$ROOTFS"
mkdir -p "$ROOTFS"
debootstrap --arch="$DEBIAN_ARCH" --variant=minbase \
	--components="$(echo $DEBIAN_COMPONENTS | tr ' ' ',')" \
	"$DEBIAN_SUITE" "$ROOTFS" "$DEBIAN_MIRROR"

log "Mounting virtual filesystems"
mount --bind /dev "$ROOTFS/dev"
mount -t proc proc "$ROOTFS/proc"
mount -t sysfs sys "$ROOTFS/sys"
cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf"

install -Dm755 "$CORE_DIR/scripts/rootfs-setup.sh" "$ROOTFS/root/rootfs-setup.sh"
rm -rf "$ROOTFS/tmp/packages"
mkdir -p "$ROOTFS/tmp/packages"
cp "$PACKAGES_DIR"/*.list "$ROOTFS/tmp/packages/"
[ -d "$DESKTOP_REPO/packages" ] && cp "$DESKTOP_REPO"/packages/*.list "$ROOTFS/tmp/packages/" 2>/dev/null || true
[ -f "$DEVICE_DIR/packages.list" ] && cp "$DEVICE_DIR/packages.list" "$ROOTFS/tmp/packages/device.list"
# The UI package list is staged under the name rootfs-setup.sh expects.
cp "$UI_DIR/packages.list" "$ROOTFS/tmp/packages/$UI.list"

# Stage hardware-specific board files before the UI overlay so each layer owns its files.
rm -rf "$ROOTFS/tmp/device-files"
if [ -d "$DEVICE_DIR/files" ]; then
	cp -a "$DEVICE_DIR/files" "$ROOTFS/tmp/device-files"
	chown -R root:root "$ROOTFS/tmp/device-files"
	chmod -R u=rwX,go=rX "$ROOTFS/tmp/device-files"
fi

# The UI file tree is staged aside; rootfs-setup.sh decides where it goes.
# The staged copy is normalised to root:root because `cp -a` would otherwise
# carry the host owner (uid 10000 on postmarketOS hosts) into the image.
rm -rf "$ROOTFS/tmp/ui-files"
if [ -d "$UI_DIR/files" ]; then
	cp -a "$UI_DIR/files" "$ROOTFS/tmp/ui-files"
	chown -R root:root "$ROOTFS/tmp/ui-files"
	chmod -R u=rwX,go=rX "$ROOTFS/tmp/ui-files"
fi

# Stage FHS runtime helpers (/usr/libexec/hayato & /etc/hayato) so the running
# device manages boot, eMMC installation, backup, and system verification without
# needing a checkout in ~/Dev/.
rm -rf "$ROOTFS/tmp/hayato-runtime" "$ROOTFS/tmp/hayato-etc" "$ROOTFS/tmp/hayato-apt"
mkdir -p "$ROOTFS/tmp/hayato-runtime/boot" "$ROOTFS/tmp/hayato-runtime/check" "$ROOTFS/tmp/hayato-etc" "$ROOTFS/tmp/hayato-apt"
cp "$CORE_DIR"/boot/*.sh "$ROOTFS/tmp/hayato-runtime/boot/"
cp "$CORE_DIR/VERSION" "$ROOTFS/tmp/hayato-runtime/VERSION"
for _rt in lib.sh lib-cgpt.sh lib-dist.sh install-emmc.sh install-boot.sh install-kpart.sh \
	make-kpart.sh backup-system.sh restore-system.sh wifi.sh check-system.sh check-core.sh hayato-apt.sh; do
	[ -f "$CORE_DIR/scripts/$_rt" ] && cp "$CORE_DIR/scripts/$_rt" "$ROOTFS/tmp/hayato-runtime/"
done
if [ -d "$CORE_DIR/apt" ]; then
	cp -a "$CORE_DIR/apt/." "$ROOTFS/tmp/hayato-apt/"
fi
cp "$CORE_DIR/scripts/check-core.sh" "$ROOTFS/tmp/hayato-runtime/check/10-core.sh"
[ -f "$DEVICE_DIR/check-device.sh" ] && cp "$DEVICE_DIR/check-device.sh" "$ROOTFS/tmp/hayato-runtime/check/20-device.sh"
[ -f "$DESKTOP_REPO/scripts/check-desktop.sh" ] && cp "$DESKTOP_REPO/scripts/check-desktop.sh" "$ROOTFS/tmp/hayato-runtime/check/30-desktop.sh"
printf '%s\n' "$DEVICE" >"$ROOTFS/tmp/hayato-etc/device"
cp "$DEVICE_DIR/deviceinfo" "$ROOTFS/tmp/hayato-etc/deviceinfo"
[ -f "$DEVICE_DIR/kernel" ] && cp "$DEVICE_DIR/kernel" "$ROOTFS/tmp/hayato-etc/kernel"
[ -f "$DEVICE_DIR/kernel-cmdline.conf" ] && cp "$DEVICE_DIR/kernel-cmdline.conf" "$ROOTFS/tmp/hayato-etc/kernel-cmdline.conf"
chown -R root:root "$ROOTFS/tmp/hayato-runtime" "$ROOTFS/tmp/hayato-etc" "$ROOTFS/tmp/hayato-apt"
# The one agent the image ships (see the Agents section of scripts/lib.sh): its
# tarball is fetched here, verified against the committed pin, and handed to
# rootfs-setup.sh, which extracts it into the user's ~/.opencode/bin. Cached in
# $SRC_DIR like the kernel and the compositor, so a rebuild downloads nothing.
if [ -f "$OPENCODE_DIR/SHA256SUMS" ]; then
	if [ ! -f "$SRC_DIR/$OPENCODE_TARBALL" ]; then
		log "Downloading $OPENCODE_TARBALL"
		curl -fL --retry 3 --progress-bar -o "$SRC_DIR/$OPENCODE_TARBALL.part" "$OPENCODE_URL"
		mv "$SRC_DIR/$OPENCODE_TARBALL.part" "$SRC_DIR/$OPENCODE_TARBALL"
	fi
	( cd "$SRC_DIR" && sha256sum -c "$OPENCODE_DIR/SHA256SUMS" ) ||
		die "checksum mismatch for $OPENCODE_TARBALL (delete $SRC_DIR/$OPENCODE_TARBALL and retry)"
	install -m 0644 "$SRC_DIR/$OPENCODE_TARBALL" "$ROOTFS/tmp/opencode.tgz"
else
	warn "no $OPENCODE_DIR/SHA256SUMS: the image gets no OpenCode"
fi
# The note editor (tools/editxr/ pins the static aarch64 release). It is not a
# Debian package, so the tarball is fetched here, verified against the committed
# pin, and handed to rootfs-setup.sh, which extracts /usr/local/bin/editxr.
if [ -f "$EDITXR_DIR/SHA256SUMS" ]; then
	if [ ! -f "$SRC_DIR/$EDITXR_TARBALL" ]; then
		log "Downloading $EDITXR_TARBALL"
		curl -fL --retry 3 --progress-bar -o "$SRC_DIR/$EDITXR_TARBALL.part" "$EDITXR_URL"
		mv "$SRC_DIR/$EDITXR_TARBALL.part" "$SRC_DIR/$EDITXR_TARBALL"
	fi
	( cd "$SRC_DIR" && sha256sum -c "$EDITXR_DIR/SHA256SUMS" ) ||
		die "checksum mismatch for $EDITXR_TARBALL (delete $SRC_DIR/$EDITXR_TARBALL and retry)"
	install -m 0644 "$SRC_DIR/$EDITXR_TARBALL" "$ROOTFS/tmp/editxr.tgz"
	# MIT: the notice travels with the binary.
	install -Dm644 "$EDITXR_DIR/LICENSE" "$ROOTFS/usr/share/doc/editxr/copyright"
else
	warn "no $EDITXR_DIR/SHA256SUMS: the image gets no editxr"
fi
# Stage the clean repository snapshot into ~/Dev/Hayato for offline inspection/rebuilds.
rm -rf "$ROOTFS/tmp/repo"
mkdir -p "$ROOTFS/tmp/repo"
_archive_git() {
	local src="$1" dst="$2"
	mkdir -p "$dst"
	if [ -e "$src/.git" ]; then
		git -c safe.directory="$src" -C "$src" archive HEAD | tar -x -C "$dst"
	else
		cp -a "$src"/. "$dst/"
		rm -rf "$dst/.git"
	fi
}
REPO_REVISION="unknown"
if [ -e "$REPO_DIR/.git" ]; then
	REPO_REVISION="$(git -c safe.directory="$REPO_DIR" -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
	_archive_git "$REPO_DIR" "$ROOTFS/tmp/repo"
fi
[ -n "${CORE_DIR:-}" ] && _archive_git "$CORE_DIR" "$ROOTFS/tmp/repo/core"
[ -n "${DESKTOP_REPO:-}" ] && _archive_git "$DESKTOP_REPO" "$ROOTFS/tmp/repo/desktop"
[ -n "${DEVICES_REPO:-}" ] && _archive_git "$DEVICES_REPO" "$ROOTFS/tmp/repo/devices"
chmod -R u=rwX,go=rX "$ROOTFS/tmp/repo"
# Which revision an image was built from, so a copy found on a card can be told
# apart from the checkout it came from.
{
	printf 'commit %s\n' "$REPO_REVISION"
	printf 'device %s\n' "$DEVICE"
	printf 'ui %s\n' "$UI"
	printf 'kernel %s\n' "$KERNEL_RELEASE"
	printf 'version %s\n' "$VERSION"
	printf 'built %s\n' "$(date -Is)"
} >"$ROOTFS/etc/debian-aarch64-revision"

log "Running rootfs-setup.sh in chroot"
chroot "$ROOTFS" env \
	HOSTNAME="$TARGET_HOSTNAME" \
	USERNAME="$USERNAME" \
	USERPASS="$USERPASS" \
	DEBIAN_SUITE="$DEBIAN_SUITE" \
	DEBIAN_MIRROR="$DEBIAN_MIRROR" \
	DEBIAN_COMPONENTS="$DEBIAN_COMPONENTS" \
	LOCALE="$LOCALE" \
	TIMEZONE="$TIMEZONE" \
	UI="$UI" \
	BOOT_TYPE="$BOOT_TYPE" \
	VERSION="$VERSION" \
	REPO_NAME="Hayato" \
	/bin/bash /root/rootfs-setup.sh

if [ -d "$WIFI_DIR" ]; then
	log "Installing Wi-Fi profiles from $WIFI_DIR"
	"$CORE_DIR/scripts/wifi.sh" import "$WIFI_DIR" "$ROOTFS"
fi

rm -rf "$ROOTFS/tmp/packages" "$ROOTFS/tmp/device-files" "$ROOTFS/tmp/ui-files" \
	"$ROOTFS/tmp/hayato-runtime" "$ROOTFS/tmp/hayato-etc" "$ROOTFS/tmp/hayato-apt" "$ROOTFS/tmp/repo" \
	"$ROOTFS/tmp/opencode.tgz" "$ROOTFS/tmp/editxr.tgz" "$ROOTFS/root/rootfs-setup.sh"

# Whatever is built here ships as a disk (write-sd.sh, make-image.sh) or is
# cloned onto one (install-emmc.sh), so it has to leave as a first boot: from an
# empty /etc/machine-id systemd generates a fresh id and the sshd-keygen
# drop-in (scripts/rootfs-setup.sh) the host keys. This is the same choice
# lib-dist.sh makes for published artifacts, for the same reasons. Left as the
# build left it, every card and every clone shares one identity - one journal,
# one dhcp identity - and ssh.service dies with "no hostkeys available".
: >"$ROOTFS/etc/machine-id"
rm -f "$ROOTFS"/etc/ssh/ssh_host_*

log "Rootfs ready: $ROOTFS"
