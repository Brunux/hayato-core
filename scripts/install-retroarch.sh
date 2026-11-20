#!/bin/bash
# Install the kiosk RetroArch package built by build-retroarch.sh.
#
# Usage: install-retroarch.sh [ROOTFS]
#
# Without an argument the rootfs built by build-rootfs.sh is used; with `/` it
# installs on the running system. The package name is `retroarch`, so this is
# also an upgrade of a machine that still has Debian's package.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

[ -n "${1:-}" ] && ROOTFS="$1"
ROOTFS="$(readlink -f "$ROOTFS" 2>/dev/null || printf '%s' "$ROOTFS")"

[ -d "$ROOTFS" ] || die "rootfs not found: $ROOTFS (run build-rootfs.sh first)"
ls "$HAYATO_STAGE"/retroarch_*.deb >/dev/null 2>&1 ||
	die "no RetroArch package in $HAYATO_STAGE (run build-retroarch.sh first)"

# The cores Depends on `retroarch`. They are installed after this package so apt
# finds the Hayato build already in place; installing them from the session list
# would pull Debian's retroarch (and its assets/Qt5) first.
CORE_LIST="${DESKTOP_REPO:-$HAYATO_DESKTOP_DIR}/packages/games.list"
CORES=""
if [ -f "$CORE_LIST" ]; then
	CORES="$(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$CORE_LIST" | tr '\n' ' ')"
fi
[ -n "$CORES" ] || CORES="libretro-core-info libretro-nestopia libretro-snes9x libretro-gambatte libretro-mgba libretro-genesisplusgx libretro-beetle-psx libretro-beetle-pce-fast libretro-beetle-vb libretro-beetle-wswan"

if [ "$(id -u)" -ne 0 ]; then
	exec sudo -n \
		BUILD_ROOT="$BUILD_ROOT" WORK_DIR="$WORK_DIR" SRC_DIR="$SRC_DIR" \
		DEVICE="$DEVICE" ROOTFS="$ROOTFS" \
		HAYATO_ROOT_DIR="${REPO_DIR:-}" HAYATO_DEVICES_DIR="${DEVICES_REPO:-}" \
		HAYATO_DESKTOP_DIR="${DESKTOP_REPO:-}" \
		"$(readlink -f "$0")"
fi

if [ "$ROOTFS" = "/" ]; then
	log "Installing RetroArch on the running system"
	DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$HAYATO_STAGE"/retroarch_*.deb
	DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $CORES
	for _core_deb in "$HAYATO_STAGE"/hayato-libretro-mupen64plus-next_*.deb \
		"$HAYATO_STAGE"/hayato-libretro-fbneo_*.deb; do
		[ -f "$_core_deb" ] || continue
		DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$_core_deb"
	done
else
	log "Installing RetroArch into $ROOTFS"
	STAGE_IN_CHROOT="/var/tmp/retroarch"
	rm -rf "$ROOTFS$STAGE_IN_CHROOT"
	mkdir -p "$ROOTFS$STAGE_IN_CHROOT"
	cp "$HAYATO_STAGE"/retroarch_*.deb "$ROOTFS$STAGE_IN_CHROOT/"
	cp "$HAYATO_STAGE"/hayato-libretro-mupen64plus-next_*.deb "$ROOTFS$STAGE_IN_CHROOT/" 2>/dev/null || true
	cp "$HAYATO_STAGE"/hayato-libretro-fbneo_*.deb "$ROOTFS$STAGE_IN_CHROOT/" 2>/dev/null || true
	# The two cores are built by stage-desktop.sh. A stage that lost them must
	# not ship an image whose Games library answers "the core is missing": the
	# build stops here. `HAYATO_ALLOW_MISSING_GAME_CORES=yes` is the explicit
	# way to build a rootfs without the game stack.
	for _core_deb in "$HAYATO_STAGE"/hayato-libretro-mupen64plus-next_*.deb \
		"$HAYATO_STAGE"/hayato-libretro-fbneo_*.deb; do
		[ -f "$_core_deb" ] && continue
		if [ "${HAYATO_ALLOW_MISSING_GAME_CORES:-no}" = yes ]; then
			warn "no $(basename "$_core_deb" .deb) package in $HAYATO_STAGE: building without that core as asked"
		else
			die "no $(basename "$_core_deb" .deb) package in $HAYATO_STAGE: the image would ship without that core (run stage-desktop.sh, or set HAYATO_ALLOW_MISSING_GAME_CORES=yes)"
		fi
	done

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
		"DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $STAGE_IN_CHROOT/*.deb"
	chroot "$ROOTFS" /bin/bash -c \
		"DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $CORES"
fi

if [ "$ROOTFS" = "/" ]; then
	_VERSION="$(retroarch --version 2>/dev/null | head -n1)"
else
	_VERSION="$(chroot "$ROOTFS" retroarch --version 2>/dev/null | head -n1)"
fi
case "$_VERSION" in
*RetroArch*) log "Installed: $_VERSION" ;;
*) die "the installed RetroArch does not answer ('${_VERSION:-retroarch --version failed}')" ;;
esac
[ "$ROOTFS" = "/" ] && [ -f /etc/hayato/retroarch.cfg ] ||
	[ -f "$ROOTFS/etc/hayato/retroarch.cfg" ] ||
	die "/etc/hayato/retroarch.cfg is missing (the library's kiosk overlay)"
