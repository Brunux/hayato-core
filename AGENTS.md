# AGENTS.md — `lazyos-core`

## Scope
Hardware-agnostic and UI-agnostic Debian arm64 (`forky`) OS assembly, partition/bootloader
backends (`boot/`), system installation (`write-sd.sh`, `install-emmc.sh`), disk imaging & release
sanitization (`make-image.sh`, `make-release.sh`, `lib-dist.sh`), backup/restore, and core system
verification (`scripts/check-core.sh` -> `/usr/libexec/lazyos/check/10-core.sh`).

Device trees, kernel recipes, board files, and SoC quirks belong in `lazyos-devices`.
Wayland desktop, Rust `lazyos` binaries, Sway configs, and themes belong in `lazyos-desktop`.

## Sub-Project Discovery (`scripts/lib.sh`)
- `CORE_DIR`: parent directory of `scripts/lib.sh`.
- `DEVICES_REPO` resolves via `$LAZYOS_DEVICES_DIR`, umbrella `../devices`, sibling `../lazyos-devices`,
  or `$REPO_DIR/devices` (`DEVICE` skips `_template` and defaults to `google-asurada`).
- `DESKTOP_REPO` resolves via `$LAZYOS_DESKTOP_DIR`, umbrella `../desktop`, sibling `../lazyos-desktop`,
  or `$REPO_DIR/desktop`.
- On a booted device (`/usr/libexec/lazyos/`), `lib.sh` falls back cleanly to `/etc/lazyos/deviceinfo`
  and `/etc/lazyos/kernel-cmdline.conf` so runtime tools work without source checkouts.
- Packaged Debian kernels (`kernels/*/package` -> `KERNEL_SOURCE_TYPE="debian-pkg"`) resolve
  `KERNEL_RELEASE` from `<rootfs>/lib/modules/*` via `resolve_kernel_release` and sync DTBs from
  `/usr/lib/linux-image-<ver>/` to `/boot/dtbs/` (`install-kernel.sh` at build time and
  `/etc/kernel/postinst.d/zz-lazyos-boot` after `apt upgrade` on non-`depthcharge` systems).

## Pluggable Boot Backend Contract (`boot/<type>.sh`)
Selected via `deviceinfo_boot_type` (`depthcharge` default, `uefi`, or `extlinux`):
- `boot_release <disk>`
- `boot_layout_create <disk>`
- `boot_layout_mount <disk> <mnt>`
- `boot_layout_umount <mnt>`
- `boot_write_fstab <mnt>`
- `boot_install <rootfs> <disk_or_out> [cmdline_extra]`
- `boot_update_running [args...]`

Keep `lib-cgpt.sh` / ChromeOS GPT safeguards intact inside `boot/depthcharge.sh`: always resolve
partitions by `PARTN` + `PARTLABEL`, refuse mounted targets via `findmnt -rn -S`, require stopping
`udisks2`, and never use `cgpt create -z`.

## Rootfs Staging & FHS Runtime Rules
- Never `rsync /` or chown existing `/` system trees recursively (preserves setuid bits and `root:root`
  `0755` on `/`, `/etc`, `/usr` required by `systemd-tmpfiles-setup`). Stage overlays under `/tmp/`
  chown'd `0:0` and copy interior entries with `(cd ... && cp -a . /)`.
- Overlay order in `rootfs-setup.sh`: `/tmp/device-files` first, then `/tmp/ui-files`. Never hardcode
  board-specific services or IRQ pinning in `rootfs-setup.sh`.
- Install runtime helpers under `/usr/libexec/lazyos/` (`install-emmc.sh`, `install-boot.sh`,
  `install-kpart.sh`, `make-kpart.sh`, `backup-system.sh`, `restore-system.sh`, `boot/`, `lib*.sh`,
  and modular checks under `/usr/libexec/lazyos/check/{10-core,20-device,30-desktop}.sh`), with
  `/usr/local/sbin/check-system.sh -> /usr/libexec/lazyos/check-system.sh`.
- Primary live-to-disk installation runs in pure Rust via `lazyos installer` (`lazyos installer apply`
  in `lazyos-desktop`); `scripts/install-emmc.sh` is kept intact in `/usr/libexec/lazyos/` as a
  manual/debug fallback for Hayato, while `scripts/install-boot.sh` (`boot_update_running`) handles
  post-upgrade boot sync across `depthcharge`, `uefi`, and `extlinux`.

## Release Sanitization (`lib-dist.sh` & `make-release.sh`)
- `make-release.sh` must strip host secrets, Wi-Fi PSKs, SSH host keys, `machine-id`, and build caches
  via `lib-dist.sh` before producing `.img.xz` / `rootfs.tar.zst` (plus `.vmlinuz.kpart` when
  `BOOT_TYPE=depthcharge`). Keep `core/VERSION` synced with `desktop/VERSION` on releases.
