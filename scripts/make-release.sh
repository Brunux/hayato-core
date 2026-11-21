#!/bin/bash
# Build the compressed release disk image of one target into a directory:
#
#   <device>.img.xz          sanitized, compressed disk image ready for `dd`
#   SHA256SUMS               SHA-256 checksum of <device>.img.xz
#
# Usage: make-release.sh [OUTDIR]     (default $WORK_DIR/release-<device>)
#
# Release notes are written by hand under docs/releases/ in the umbrella repo
# and reused for the annotated tag and GitHub release body. Everything inside
# the image is sanitized and asserted clean (scripts/lib-dist.sh): a released
# image must not carry Wi-Fi PSKs, SSH host keys, or a fixed machine-id.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
. "$BOOT_BACKEND"
. "$(dirname "$0")/lib-dist.sh"

OUTDIR="${1:-$WORK_DIR/release-$DEVICE}"
export IMAGE_SIZE_MIB

# build-rootfs.sh documents the same pitfall: sudo drops the environment, so
# every resolved input is forwarded explicitly.
if [ "$(id -u)" -ne 0 ]; then
	exec sudo -n DEVICE="$DEVICE" IMAGE_SIZE_MIB="$IMAGE_SIZE_MIB" \
		BUILD_ROOT="$BUILD_ROOT" WORK_DIR="$WORK_DIR" SRC_DIR="$SRC_DIR" \
		HAYATO_ROOT_DIR="${REPO_DIR:-}" HAYATO_DEVICES_DIR="${DEVICES_REPO:-}" \
		HAYATO_DESKTOP_DIR="${DESKTOP_REPO:-}" \
		"$(readlink -f "$0")" "$OUTDIR"
fi

IMG="$OUTDIR/$DEVICE.img"

mkdir -p "$OUTDIR"
[ -d "$ROOTFS" ] || die "rootfs not found: $ROOTFS (run build-rootfs.sh first)"

log "1/3 Image"
"$CORE_DIR/scripts/make-image.sh" "$IMG" "$IMAGE_SIZE_MIB"

log "2/3 Compressing image"
xz -T0 -6 -f "$IMG"

log "3/3 Staging .deb packages"
for _deb in \
	"$COMPOSITOR_STAGE"/*.deb \
	"$WORKSTYLE_STAGE"/*.deb \
	"$HAYATO_STAGE"/*.deb \
	"$KERNEL_STAGE"/*.deb; do
	[ -f "$_deb" ] || continue
	_base="$(basename "$_deb")"
	case "$_base" in
		hayato-device-*)
			case "$_base" in
				"hayato-device-${DEVICE}_"*) cp -f "$_deb" "$OUTDIR/" ;;
			esac
			;;
		*)
			cp -f "$_deb" "$OUTDIR/"
			;;
	esac
done

log "Checksums"
(
	cd "$OUTDIR"
	rm -f SHA256SUMS
	sha256sum "$(basename "$IMG").xz" *.deb 2>/dev/null >SHA256SUMS ||
		sha256sum "$(basename "$IMG").xz" >SHA256SUMS
	cat SHA256SUMS
) | sed 's/^/  /'

log "Assets in $OUTDIR"
ls -lh "$OUTDIR" | sed 's/^/  /'
