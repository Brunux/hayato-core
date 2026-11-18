#!/bin/bash
# Full build pipeline for the selected device (does NOT touch any block device).
#
# Produces, under $WORK_DIR:
#   kernel-stage-<flavor>/  built kernel, modules, dtbs
#   swayfx-stage/           the compositor's .debs (scenefx + swayfx)
#   workstyle-stage/        the workspace renamer's .deb
#   lazyos-stage/           the session framework binary, lazyos-games and the game stack
#   rootfs-<device>/        Debian rootfs with the kernel, compositor, workstyle and lazyos installed
#   <device>.vmlinuz.kpart  signed depthcharge FIT kernel partition image
#
# To write the result to a microSD/USB device, run scripts/write-sd.sh.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

require_devices
require_desktop

if [ "${SKIP_KERNEL_BUILD:-no}" != "yes" ]; then
	"$DEVICES_REPO/scripts/build-kernel.sh"
fi
if [ "${SKIP_DESKTOP_BUILD:-no}" != "yes" ]; then
	# The rootfs does not install Debian's sway (uis/sway/packages.list), so the
	# compositor has to be built before the image is useful.
	"$DESKTOP_REPO/scripts/build-swayfx.sh"
	# Debian packages no workspace renamer, and the bar's pills depend on it.
	"$DESKTOP_REPO/scripts/build-workstyle.sh"
	# The session framework (docs/plan-ui.md): one binary, built from lazyos-desktop's
	# Rust workspace.
	"$DESKTOP_REPO/scripts/build-lazyos.sh"
fi
"$CORE_DIR/scripts/build-rootfs.sh"
"$CORE_DIR/scripts/install-kernel.sh"
"$CORE_DIR/scripts/install-swayfx.sh"
"$CORE_DIR/scripts/install-workstyle.sh"
"$CORE_DIR/scripts/install-lazyos.sh"
"$CORE_DIR/scripts/install-retroarch.sh"
if [ "$BOOT_TYPE" = "depthcharge" ]; then
	"$CORE_DIR/scripts/make-kpart.sh"
fi

log "Build complete."
log "  device : $DEVICE"
log "  compositor : $COMPOSITOR $COMPOSITOR_VERSION (scenefx $SCENEFX_VERSION)"
log "  workstyle : $WORKSTYLE_VERSION"
log "  rootfs : $ROOTFS"
log "  kpart  : $KPART"
log "Next: scripts/write-sd.sh /dev/mmcblk1"
