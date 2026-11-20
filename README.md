# `hayato-core`

Hardware- and desktop-agnostic Debian arm64 OS assembly, pluggable bootloader backends,
installer, backup/restore, release imaging, and core system diagnostics for
[Hayato](https://github.com/Brunux/Hayato).

## Architecture

- `boot/` — Pluggable boot backends (`depthcharge.sh`, `uefi.sh`, `extlinux.sh`) selected via
  `deviceinfo_boot_type`.
- `packages/base.list` — Minimal Debian `forky` system package set.
- `scripts/build.sh` — Orchestrates device kernel build, desktop staging, rootfs assembly, and boot
  image generation.
- `scripts/build-rootfs.sh` & `scripts/rootfs-setup.sh` — Debootstraps Debian `arm64`, merges
  core/desktop/device package lists and overlays, and installs `/usr/libexec/hayato/`.
- `scripts/check-system.sh` & `scripts/check-core.sh` — Runs `10-core.sh` + optional `20-device.sh`
  and `30-desktop.sh` hardware/desktop witnesses.
- `scripts/write-sd.sh`, `scripts/install-boot.sh`, `scripts/make-image.sh`, `scripts/make-release.sh`
  — Disk layout, bootloader updates, and sanitized release artifact builders (`scripts/install-emmc.sh`
  remains kept intact as the legacy Hayato manual/debug fallback for pure-Rust `hayato installer`).
