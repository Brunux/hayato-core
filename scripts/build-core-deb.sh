#!/bin/bash
# Build hayato-core_<version>-1hayato1_<arch>.deb (and hayato-device-<device>.deb
# when hayato-devices is present) into $HAYATO_STAGE.
#
# Usage: build-core-deb.sh [OUTDIR]
set -euo pipefail
umask 022
. "$(dirname "$0")/lib.sh"

OUTDIR="${1:-$HAYATO_STAGE}"
VERSION="$(tr -d ' \t\r\n' <"$CORE_DIR/VERSION")"
PACKAGING_REVISION="1hayato1"
PKG_VERSION="${VERSION}-${PACKAGING_REVISION}"
DEB_ARCH="$(dpkg --print-architecture 2>/dev/null || echo "$DEBIAN_ARCH")"

PKG="$WORK_DIR/hayato-core-pkg"
rm -rf "$PKG"

install -d -m 0755 \
	"$PKG/usr/libexec/hayato/boot" \
	"$PKG/usr/libexec/hayato/check" \
	"$PKG/usr/local/sbin" \
	"$PKG/usr/share/keyrings" \
	"$PKG/etc/apt/keyrings" \
	"$PKG/etc/apt/sources.list.d" \
	"$PKG/etc/depthcharge-tools" \
	"$PKG/etc/kernel/postinst.d" \
	"$PKG/etc/initramfs/post-update.d" \
	"$PKG/etc/systemd/system/sshd-keygen.service.d" \
	"$PKG/etc/systemd/system/systemd-user-sessions.service.d" \
	"$PKG/etc/sysctl.d" \
	"$PKG/etc/tmpfiles.d" \
	"$PKG/etc/udev/rules.d"

install -m 0644 "$CORE_DIR/VERSION" "$PKG/usr/libexec/hayato/VERSION"
for _b in "$CORE_DIR"/boot/*.sh; do
	[ -f "$_b" ] || continue
	install -m 0755 "$_b" "$PKG/usr/libexec/hayato/boot/$(basename "$_b")"
done
for _rt in lib.sh lib-cgpt.sh lib-dist.sh install-emmc.sh install-boot.sh install-kpart.sh \
	make-kpart.sh backup-system.sh restore-system.sh wifi.sh check-system.sh check-core.sh hayato-apt.sh; do
	[ -f "$CORE_DIR/scripts/$_rt" ] && install -m 0755 "$CORE_DIR/scripts/$_rt" "$PKG/usr/libexec/hayato/$_rt"
done
install -m 0755 "$CORE_DIR/scripts/check-core.sh" "$PKG/usr/libexec/hayato/check/10-core.sh"
ln -sfn /usr/libexec/hayato/check-system.sh "$PKG/usr/local/sbin/check-system.sh"
ln -sfn /usr/libexec/hayato/hayato-apt.sh "$PKG/usr/local/sbin/hayato-apt"

if [ -f "$CORE_DIR/apt/hayato-archive-keyring.gpg" ]; then
	install -m 0644 "$CORE_DIR/apt/hayato-archive-keyring.gpg" "$PKG/usr/share/keyrings/hayato-archive-keyring.gpg"
	install -m 0644 "$CORE_DIR/apt/hayato-archive-keyring.gpg" "$PKG/etc/apt/keyrings/hayato-archive-keyring.gpg"
fi
if [ -f "$CORE_DIR/apt/hayato-archive-keyring.asc" ]; then
	install -m 0644 "$CORE_DIR/apt/hayato-archive-keyring.asc" "$PKG/usr/share/keyrings/hayato-archive-keyring.asc"
fi
if [ -f "$CORE_DIR/apt/hayato.sources" ]; then
	install -m 0644 "$CORE_DIR/apt/hayato.sources" "$PKG/etc/apt/sources.list.d/hayato.sources"
fi

cat >"$PKG/etc/depthcharge-tools/config" <<'EOF'
[depthchargectl/write]
enable-system-hooks = False
EOF

cat >"$PKG/etc/systemd/zram-generator.conf" <<'EOF'
[zram0]
zram-size = ram / 2
compression-algorithm = lz4
swap-priority = 100
EOF

cat >"$PKG/etc/sysctl.d/90-zram-emmc.conf" <<'EOF'
vm.swappiness = 100
vm.vfs_cache_pressure = 100
vm.page-cluster = 0
vm.watermark_boost_factor = 0
vm.watermark_scale_factor = 125
vm.compaction_proactiveness = 0
vm.dirty_bytes = 67108864
vm.dirty_background_bytes = 16777216
EOF

cat >"$PKG/etc/tmpfiles.d/mglru.conf" <<'EOF'
w /sys/kernel/mm/lru_gen/min_ttl_ms - - - - 1000
EOF

cat >"$PKG/etc/udev/rules.d/60-io-scheduler.rules" <<'EOF'
ACTION=="add|change", KERNEL=="mmcblk[0-9]|nvme[0-9]*n[0-9]*|sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="kyber"
EOF

cat >"$PKG/etc/systemd/system/sshd-keygen.service.d/90-run-when-keys-are-missing.conf" <<'EOF'
[Unit]
ConditionFirstBoot=
ConditionPathExists=!/etc/ssh/ssh_host_ed25519_key
EOF

cat >"$PKG/etc/systemd/system/systemd-user-sessions.service.d/90-no-network-wait.conf" <<'EOF'
[Unit]
After=
After=remote-fs.target nss-user-lookup.target
EOF

ln -sfn /dev/null "$PKG/etc/systemd/system/systemd-binfmt.service"

cat >"$PKG/etc/kernel/postinst.d/zz-hayato-boot" <<'EOF'
#!/bin/sh
# Sync packaged DTBs and refresh the active boot partition / entry (depthcharge, uefi, extlinux).
set -eu
ver="${1:-}"
case "$ver" in
	*/* | *..*) exit 1 ;;
esac
if [ -n "$ver" ] && [ -d "/usr/lib/linux-image-$ver" ]; then
	rm -rf /boot/dtbs
	mkdir -p /boot/dtbs
	cp -a "/usr/lib/linux-image-$ver/." /boot/dtbs/
fi
_root_id="$(stat -Lc %d:%i / 2>/dev/null || true)"
_pid1_id="$(stat -Lc %d:%i /proc/1/root 2>/dev/null || true)"
if [ -n "$_root_id" ] && [ -n "$_pid1_id" ] && [ "$_root_id" != "$_pid1_id" ]; then
	exit 0
fi
if [ -n "$ver" ] && { [ ! -f "/boot/vmlinuz-$ver" ] || [ ! -f "/boot/initrd.img-$ver" ]; }; then
	exit 0
fi
if [ -n "$ver" ] && [ -d /run ]; then
	_sig="$(stat -c '%Y:%s' "/boot/vmlinuz-$ver" "/boot/initrd.img-$ver" 2>/dev/null | tr '\n' ' ' || true)"
	_stamp="/run/hayato-boot-synced-$ver"
	if [ -n "$_sig" ] && [ -f "$_stamp" ] && [ "$(cat "$_stamp" 2>/dev/null || true)" = "$_sig" ]; then
		exit 0
	fi
fi
if [ -x /usr/libexec/hayato/install-boot.sh ] && findmnt -n -o UUID / >/dev/null 2>&1; then
	CONFIRM=yes TARGET_KERNEL_RELEASE="$ver" /usr/libexec/hayato/install-boot.sh
	if [ -n "$ver" ] && [ -d /run ] && [ -n "${_sig:-}" ]; then
		printf '%s' "$_sig" >"/run/hayato-boot-synced-$ver" 2>/dev/null || true
	fi
fi
EOF
chmod 0755 "$PKG/etc/kernel/postinst.d/zz-hayato-boot"
install -m 0755 "$PKG/etc/kernel/postinst.d/zz-hayato-boot" "$PKG/etc/initramfs/post-update.d/zz-hayato-boot"
chmod -R go-w "$PKG"

INSTALLED_SIZE="$(du -sk --exclude=DEBIAN "$PKG" | cut -f1)"
mkdir -p "$PKG/DEBIAN" "$OUTDIR"
cat >"$PKG/DEBIAN/control" <<EOF
Package: hayato-core
Version: $PKG_VERSION
Architecture: $DEB_ARCH
Maintainer: Hayato <maintainers@hayato.org>
Installed-Size: $INSTALLED_SIZE
Section: admin
Priority: required
Homepage: https://github.com/Brunux/Hayato
Description: Hayato core runtime helpers, boot backends, system tuning, and APT configuration
 Pluggable boot backends (depthcharge, uefi, extlinux), live kernel/kpart upgrade
 hooks, backup/restore utilities, zram/MGLRU/kyber tuning, modular health checks,
 and the Hayato APT repository keyring.
EOF

cat >"$PKG/DEBIAN/postinst" <<EOF
#!/bin/sh
set -e
rm -f /etc/os-release
cat >/etc/os-release <<'OSREL'
PRETTY_NAME="Hayato $VERSION"
NAME="Hayato"
VERSION_ID="$VERSION"
VERSION="Hayato $VERSION"
ID=hayato
ID_LIKE=debian
HOME_URL="https://github.com/Brunux/Hayato"
BUG_REPORT_URL="https://github.com/Brunux/Hayato/issues"
LOGO=hayato
OSREL

cat >/etc/issue <<'ISSUE'
Hayato $VERSION · light. fast. fun.
\n · \l
ISSUE

if [ -f /etc/debian-aarch64-revision ]; then
	sed -i "s|^version .*|version $VERSION|" /etc/debian-aarch64-revision
fi

_root_id="\$(stat -Lc %d:%i / 2>/dev/null || true)"
_pid1_id="\$(stat -Lc %d:%i /proc/1/root 2>/dev/null || true)"
if [ -n "\$_root_id" ] && [ -n "\$_pid1_id" ] && [ "\$_root_id" = "\$_pid1_id" ]; then
	command -v sysctl >/dev/null 2>&1 && sysctl --system >/dev/null 2>&1 || true
	command -v udevadm >/dev/null 2>&1 && udevadm control --reload-rules 2>/dev/null || true
	command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload 2>/dev/null || true
fi
exit 0
EOF
chmod 0755 "$PKG/DEBIAN/postinst"

rm -f "$OUTDIR"/hayato-core_*.deb
DEB="$OUTDIR/hayato-core_${PKG_VERSION}_${DEB_ARCH}.deb"
dpkg-deb --build --root-owner-group "$PKG" "$DEB" >/dev/null
log "hayato-core $VERSION -> $DEB"

if [ -n "${DEVICES_REPO:-}" ] && [ -x "$DEVICES_REPO/scripts/build-device-deb.sh" ]; then
	HAYATO_VERSION="$VERSION" DEVICE="$DEVICE" "$DEVICES_REPO/scripts/build-device-deb.sh" "$OUTDIR"
fi
