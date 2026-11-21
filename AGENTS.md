# AGENTS.md — `hayato-core`

## Scope
Hardware-agnostic and UI-agnostic Debian arm64 (`forky`) OS assembly, partition/bootloader
backends (`boot/`), system installation (`write-sd.sh`, `install-emmc.sh`), disk imaging & release
sanitization (`make-image.sh`, `make-release.sh`, `lib-dist.sh`), backup/restore, and core system
verification (`scripts/check-core.sh` -> `/usr/libexec/hayato/check/10-core.sh`).

Device trees, kernel recipes, board files, and SoC quirks belong in `hayato-devices`.
Wayland desktop, Rust `hayato` binaries, Sway configs, and themes belong in `hayato-desktop`.

## Sub-Project Discovery (`scripts/lib.sh`)
- `CORE_DIR`: parent directory of `scripts/lib.sh`.
- `DEVICES_REPO` resolves via `$HAYATO_DEVICES_DIR`, umbrella `../devices`, sibling `../hayato-devices`,
  or `$REPO_DIR/devices` (`DEVICE` skips `_template` and defaults to `google-asurada`).
- `DESKTOP_REPO` resolves via `$HAYATO_DESKTOP_DIR`, umbrella `../desktop`, sibling `../hayato-desktop`,
  or `$REPO_DIR/desktop`.
- On a booted device (`/usr/libexec/hayato/`), `lib.sh` falls back cleanly to `/etc/hayato/deviceinfo`
  and `/etc/hayato/kernel-cmdline.conf` so runtime tools work without source checkouts.
- Packaged Debian kernels (`kernels/*/package` -> `KERNEL_SOURCE_TYPE="debian-pkg"`) and packaged
  Hayato kernels (`linux-image-hayato-<flavor>`) resolve `KERNEL_RELEASE` and sync DTBs from
  `/usr/lib/linux-image-<ver>/` to `/boot/dtbs/` (`install-kernel.sh` at build time and
  `/etc/kernel/postinst.d/zz-hayato-boot` + `/etc/initramfs/post-update.d/zz-hayato-boot` after
  `apt upgrade` across all boot backends including `depthcharge`, which deduplicates consecutive
  postinst/initramfs triggers via `/run/hayato-boot-synced-<ver>` and forwards
  `TARGET_KERNEL_RELEASE` to `install-kpart.sh`).
- In-place `.deb` distribution (`scripts/build-core-deb.sh`, `scripts/install-core.sh`,
  `scripts/hayato-apt.sh`, and `apt/`): `hayato-core` packages `/usr/libexec/hayato/`, tuning drop-ins,
  `zz-hayato-boot` hooks, `/usr/share/keyrings/hayato-archive-keyring.gpg`, and
  `/etc/apt/sources.list.d/hayato.sources` (Cloudsmith APT repository + GitHub Releases
  `hayato-apt upgrade-from-github` fallback). `make-release.sh` stages all target `.deb` packages
  alongside `<device>.img.xz` into `$OUTDIR` and records them in `SHA256SUMS`.

## Pluggable Boot Backend Contract (`boot/<type>.sh`)
Selected via `deviceinfo_boot_type` (`depthcharge` default, `uefi`, or `extlinux`):
- `boot_release <disk>`
- `boot_layout_create <disk>`
- `boot_layout_mount <disk> <mnt>`
- `boot_layout_umount <mnt>`
- `boot_write_fstab <mnt>`
- `boot_install <rootfs> <disk_or_out> [cmdline_extra]`
- `boot_update_running [args...]`

All `rsync -aHAX --delete` syncs into a `boot_layout_mount` target must exclude `/boot/efi`
so a mounted FAT32 ESP (`uefi`) is neither deleted (`EBUSY`) nor synced with POSIX metadata;
image/SD syncs (`sync_rootfs_to_mount` in `lib.sh`) sync `/` (`--exclude=/boot`) and `/boot/`
(`--exclude=/efi`) in two passes so Debian kernel hard links spanning `/` and a separate `/boot`
partition (`extlinux`/`depthcharge`) never trigger `EXDEV`, and `boot_install` populates `/boot` or
`/boot/efi` afterward.

Keep `lib-cgpt.sh` / ChromeOS GPT safeguards intact inside `boot/depthcharge.sh`: always resolve
partitions by `PARTN` + `PARTLABEL` (falling back to `/sys/block/<disk>/<part>/dev` + `mknod` and
`blkid -s PARTLABEL` when building loop images inside a container without a container-side `udevd`),
refuse mounted targets via `findmnt -rn -S`, require stopping `udisks2`, and never use `cgpt create -z`.

## Rootfs Staging & FHS Runtime Rules
- Never `rsync /` or chown existing `/` system trees recursively (preserves setuid bits and `root:root`
  `0755` on `/`, `/etc`, `/usr` required by `systemd-tmpfiles-setup`). Stage overlays under `/tmp/`
  chown'd `0:0` and copy interior entries with `(cd ... && cp -a . /)`.
- Overlay order in `rootfs-setup.sh`: `/tmp/device-files` first, then `/tmp/ui-files`. Never hardcode
  board-specific services or IRQ pinning in `rootfs-setup.sh`.
- Install runtime helpers under `/usr/libexec/hayato/` (`install-emmc.sh`, `install-boot.sh`,
  `install-kpart.sh`, `make-kpart.sh`, `backup-system.sh`, `restore-system.sh`, `boot/`, `lib*.sh`,
  and modular checks under `/usr/libexec/hayato/check/{10-core,20-device,30-desktop}.sh`), with
  `/usr/local/sbin/check-system.sh -> /usr/libexec/hayato/check-system.sh`.
- Primary live-to-disk installation runs in pure Rust via `hayato installer` (`hayato installer apply`
  in `hayato-desktop`); `scripts/install-emmc.sh` is kept intact in `/usr/libexec/hayato/` as a
  manual/debug fallback for Hayato, while `scripts/install-boot.sh` (`boot_update_running`) handles
  post-upgrade boot sync across `depthcharge`, `uefi`, and `extlinux`.
- Boot-speed defaults: ChromeOS `depthcharge` boards (`google-asurada`, `google-kukui`) use fast
  `lz4` FIT kernel compression (`deviceinfo_depthcharge_compression="lz4"` with `lz4` in board
  `packages.list`); `rootfs-setup.sh` and `hayato-core` mask `systemd-binfmt.service` and drop
  `network.target` from `systemd-user-sessions.service`'s `After=` list so `greetd` starts in
  parallel with `NetworkManager` and `ssh`.

## Release Sanitization (`lib-dist.sh` & `make-release.sh`)
- `make-release.sh` must strip host secrets, Wi-Fi PSKs, SSH host keys, `machine-id`, and build caches
  via `lib-dist.sh` before producing the sanitized `<device>.img.xz` release image and `SHA256SUMS`.
  Keep `core/VERSION` synced with `desktop/VERSION` on releases.
- The agent's configuration is product, not state: keep `/home/*/.config/opencode/opencode.json` and
  `AGENTS.md`, and strip only `service.json`/`auth.json`. Excluding the whole directory shipped an
  image whose OpenCode never started `hayato mcp`.
- The build states `umask 022` (`build.sh`, `build-rootfs.sh`): a desktop user's `0002` reaches
  debootstrap and makes `/`, `/etc` and `/usr` `0775`, which `systemd-tmpfiles-setup` refuses to
  accept as the FHS layout.

## Tests (`tests/`)
- `bash tests/run.sh` runs the dependency-free shell suites for `lib.sh` (device discovery, kernel
  metadata, boot cmdline), `lib-dist.sh` (sanitization and leak checks), `lib-cgpt.sh` (GPT geometry,
  partition resolution, fstab) and `wifi.sh` (profile import/export). Block devices, `cgpt`/`parted`,
  `install -o root` and `need_root` are shimmed, so the suite runs unprivileged.
- `.github/workflows/core.yml` and `./build.sh validate` run it; add a case there when a helper in
  those files gains a branch that a boot, image or Wi-Fi failure could hit.
