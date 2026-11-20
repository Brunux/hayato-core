#!/bin/bash
# Install the session framework binary into a root filesystem (or `/`).
#
# Usage:
#   install-hayato.sh [ROOTFS]
#
# Without an argument the rootfs built by build-rootfs.sh is used;
# `install-hayato.sh /` installs it on the running system, which is the
# counterpart of install-kpart.sh when the binary changes.
#
# Three things land: /usr/bin/hayato, the symlinks /usr/bin/hayato-menu and
# /usr/bin/hayato-task -> hayato, and the game library (/usr/bin/hayato-games
# plus /usr/share/hayato/games). The links are the "migrated set"
# check-system.sh validates: a name whose `check-system.sh` line must resolve,
# and whose command must be in `--help`.
# The ~64 old names under ~/.config/bin join it one spec at a time, because each
# one replaces a script that still has to work until its surface is ported; those
# links are in the UI tree (bar-menu since spec 007), not made here, and
# check-system.sh accepts an installed name in either place.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

[ -n "${1:-}" ] && ROOTFS="$1"
ROOTFS="$(readlink -f "$ROOTFS" 2>/dev/null || printf '%s' "$ROOTFS")"

[ -x "$HAYATO_STAGE/hayato" ] ||
	die "no hayato binary in $HAYATO_STAGE (run build-hayato.sh first)"
[ -d "$ROOTFS/usr/bin" ] || die "not a root filesystem: $ROOTFS/usr/bin is missing"

if [ "$(id -u)" -ne 0 ]; then
	exec sudo -n \
		BUILD_ROOT="$BUILD_ROOT" WORK_DIR="$WORK_DIR" SRC_DIR="$SRC_DIR" \
		DEVICE="$DEVICE" ROOTFS="$ROOTFS" \
		HAYATO_ROOT_DIR="${REPO_DIR:-}" HAYATO_DEVICES_DIR="${DEVICES_REPO:-}" \
		HAYATO_DESKTOP_DIR="${DESKTOP_REPO:-}" \
		"$(readlink -f "$0")"
fi

if [ "$ROOTFS" = "/" ]; then
	log "Installing hayato on the running system"
else
	log "Installing hayato into $ROOTFS"
fi

install -m 0755 "$HAYATO_STAGE/hayato" "$ROOTFS/usr/bin/hayato"
if [ -f "$HAYATO_STAGE/hayato-notify" ]; then
	install -m 0755 "$HAYATO_STAGE/hayato-notify" "$ROOTFS/usr/bin/hayato-notify"
fi
if [ -f "$HAYATO_STAGE/hayato-games" ]; then
	install -m 0755 "$HAYATO_STAGE/hayato-games" "$ROOTFS/usr/bin/hayato-games"
fi
if [ -d "$HAYATO_STAGE/share/hayato/games" ]; then
	install -d "$ROOTFS/usr/share/hayato/games"
	cp -a "$HAYATO_STAGE/share/hayato/games/." "$ROOTFS/usr/share/hayato/games/"
fi

# Every name the command table says is installed, made here - not just the two
# the framework bootstrapped with. The table's `installed` field is what
# check-system.sh validates, so a name it lists and this script does not create
# is a FAIL on the device for a surface that works when typed. Reading the list
# out of the binary (rather than repeating it here) is what keeps the two from
# drifting: the binary is the source of truth, and `--symlinks` is its own
# answer.
while IFS='	' read -r _name _path; do
	[ -n "$_name" ] || continue
	ln -sfn hayato "$ROOTFS/usr/bin/$_name"
done < <("$ROOTFS/usr/bin/hayato" --symlinks)

# Read back what was written: a binary that does not answer is a broken copy,
# and the version is what check-system.sh compares with the image's record.
REPORTED="$("$ROOTFS/usr/bin/hayato" --version 2>/dev/null || true)"
_VER_FILE="$CORE_DIR/VERSION"
[ -n "${DESKTOP_REPO:-}" ] && [ -f "$DESKTOP_REPO/VERSION" ] && _VER_FILE="$DESKTOP_REPO/VERSION"
[ "$REPORTED" = "$(cat "$_VER_FILE")" ] ||
	die "$ROOTFS/usr/bin/hayato does not report $(cat "$_VER_FILE") (got '$REPORTED')"

if [ -x "$ROOTFS/usr/bin/hayato-games" ]; then
	_GAMES_REPORTED="$("$ROOTFS/usr/bin/hayato-games" --version 2>/dev/null || true)"
	[ "$_GAMES_REPORTED" = "$(cat "$_VER_FILE")" ] ||
		die "$ROOTFS/usr/bin/hayato-games does not report $(cat "$_VER_FILE") (got '$_GAMES_REPORTED')"
	[ -f "$ROOTFS/usr/share/hayato/games/theme-default.css" ] ||
		die "$ROOTFS/usr/share/hayato/games/theme-default.css is missing (run build-hayato.sh)"
fi

# One FAIL-shaped answer per name here beats a dozen on the card: a link that
# does not resolve is the key that opens nothing, and only this script can say
# so before the image is written.
_missing=
while IFS='	' read -r _name _path; do
	[ -n "$_name" ] || continue
	[ -x "$ROOTFS/usr/bin/$_name" ] || _missing="$_missing $_name"
done < <("$ROOTFS/usr/bin/hayato" --symlinks)
[ -z "$_missing" ] ||
	die "these installed names do not resolve to the binary:$_missing"

log "hayato $REPORTED installed; its menu opens with 'hayato menu' from the session"
