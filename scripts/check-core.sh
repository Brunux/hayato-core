#!/bin/bash
# LazyOS hardware- and UI-agnostic core OS checks (/usr/libexec/lazyos/check/10-core.sh).
# Can run standalone (./scripts/check-core.sh) or sourced by check-system.sh.

_STANDALONE_CORE=0
if [ "${_CHECK_SYSTEM_SOURCED:-0}" != 1 ]; then
	_STANDALONE_CORE=1
	set -u
	PASS=0 WARN=0 FAIL=0 SECTION="" SUMMARY_ONLY=0
	PRIV=no
	if [ "$(id -u)" -eq 0 ] || sudo -n true 2>/dev/null; then
		PRIV=yes
	fi
	if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
		C_OK='\033[1;32m' C_WARN='\033[1;33m' C_FAIL='\033[1;31m'
		C_INFO='\033[0;36m' C_DIM='\033[2m' C_HEAD='\033[1;37m' C_OFF='\033[0m'
	else
		C_OK="" C_WARN="" C_FAIL="" C_INFO="" C_DIM="" C_HEAD="" C_OFF=""
	fi
	if [ "${1:-}" = "--summary" ]; then SUMMARY_ONLY=1; shift; fi
	section() { SECTION="$1"; [ "$SUMMARY_ONLY" = 1 ] || printf '\n%s==> %s%s\n' "$C_HEAD" "$1" "$C_OFF"; }
	ok()   { PASS=$((PASS + 1)); [ "$SUMMARY_ONLY" = 1 ] || printf "  ${C_OK}%-4s${C_OFF}  %s\n" OK "$*"; }
	warn() { WARN=$((WARN + 1)); printf "  ${C_WARN}%-4s${C_OFF}  [%s] %s\n" WARN "$SECTION" "$*"; }
	fail() { FAIL=$((FAIL + 1)); printf "  ${C_FAIL}%-4s${C_OFF}  [%s] %s\n" FAIL "$SECTION" "$*"; }
	skip() { [ "$SUMMARY_ONLY" = 1 ] || printf "  ${C_DIM}%-4s${C_OFF}  %s\n" SKIP "$*"; }
	info() { [ "$SUMMARY_ONLY" = 1 ] || printf "  ${C_INFO}%-4s${C_OFF}  %s\n" INFO "$*"; }
	have() { command -v "$1" >/dev/null 2>&1; }
	asroot() { if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo -n "$@"; fi; }
	check_svc() {
		local u="$1" desc="${2:-$1 is active}"
		if ! have systemctl; then skip "no systemctl ($u)"; return 0; fi
		if systemctl is-active --quiet "$u" 2>/dev/null; then ok "$desc"
		else warn "$u is not active"; fi
	}
fi

# ---------------------------------------------------------------------------
section "Boot"
# ---------------------------------------------------------------------------
info "kernel  $(uname -r)"
CMDLINE="$(cat /proc/cmdline 2>/dev/null || true)"
info "cmdline $CMDLINE"
case "$CMDLINE" in
	*root=UUID=*) ok "root=UUID= present" ;;
	*)            warn "the cmdline does not select the root filesystem by UUID" ;;
esac

if [ -d "/lib/modules/$(uname -r)" ]; then
	ok "modules for $(uname -r) installed"
else
	fail "no /lib/modules/$(uname -r): the running kernel does not match the installed modules"
fi

if [ -f /etc/lazyos/deviceinfo ]; then
	# shellcheck disable=SC1091
	_boot_type="$(sed -n 's/^deviceinfo_boot_type=["'\'']*\([^"'\'' ]*\).*/\1/p' /etc/lazyos/deviceinfo | head -n1)"
	case "${_boot_type:-}" in
		uefi)
			[ -f /boot/efi/loader/entries/lazyos.conf ] &&
				ok "UEFI systemd-boot entry present (/boot/efi/loader/entries/lazyos.conf)" ||
				fail "/boot/efi/loader/entries/lazyos.conf is missing" ;;
		extlinux)
			[ -f /boot/extlinux/extlinux.conf ] &&
				ok "extlinux config present (/boot/extlinux/extlinux.conf)" ||
				fail "/boot/extlinux/extlinux.conf is missing" ;;
	esac
fi

# ---------------------------------------------------------------------------
section "Root filesystem"
# ---------------------------------------------------------------------------
for _d in / /etc /usr; do
	_down="$(stat -c '%U:%G' "$_d" 2>/dev/null)"
	_dmode="$(stat -c '%a' "$_d" 2>/dev/null)"
	if [ "$_down" != root:root ]; then
		fail "$_d is owned by ${_down:-nobody}, not root:root: tmpfiles exits 73 and UCM/session units break"
	elif [ "$_dmode" != 755 ]; then
		warn "$_d is $_dmode, not 755 (harmless here, not what the build produces)"
	else
		ok "$_d is 755 root:root"
	fi
done

if [ -d /run/lock ]; then
	ok "/run/lock exists (systemd-tmpfiles-setup ran)"
else
	fail "/run/lock is missing: systemd-tmpfiles-setup did not create it"
fi

_priv_bad=""
while read -r _p _want; do
	[ -e "$_p" ] || continue
	_got="$(stat -c '%a %U:%G' "$_p" 2>/dev/null)"
	[ "$_got" = "$_want" ] || _priv_bad="$_priv_bad $_p(${_got:-unreadable}, want $_want)"
done <<'SETID'
/usr/bin/sudo 4755 root:root
/usr/bin/su 4755 root:root
/usr/bin/mount 4755 root:root
/usr/bin/umount 4755 root:root
/usr/bin/passwd 4755 root:root
/usr/bin/chfn 4755 root:root
/usr/bin/chsh 4755 root:root
/usr/bin/gpasswd 4755 root:root
/usr/bin/chage 2755 root:shadow
/usr/sbin/unix_chkpwd 2755 root:shadow
/usr/lib/openssh/ssh-keysign 4755 root:root
/usr/lib/dbus-1.0/dbus-daemon-launch-helper 4754 root:messagebus
/etc/shadow 640 root:shadow
/etc/gshadow 640 root:shadow
SETID
if [ -z "$_priv_bad" ]; then
	ok "the setuid helpers and the shadow files keep their mode and group"
else
	fail "wrong mode/owner:$_priv_bad (restore setuid/group bits)"
fi

# ---------------------------------------------------------------------------
section "Firmware"
# ---------------------------------------------------------------------------
if have dmesg && [ "$PRIV" = yes ]; then
	_dmesg="$(asroot dmesg 2>/dev/null || true)"
	_missing="$(printf '%s\n' "$_dmesg" | grep -oE 'Direct firmware load for [^ ]+ failed' |
		awk '{print $5}' | sort -u || true)"
	if [ -z "$_missing" ]; then
		ok "no failed firmware loads in dmesg"
	else
		for _fw in $_missing; do
			if grep -q "Booting fw image $_fw" <<<"$_dmesg"; then
				ok "firmware $_fw: requested in initramfs, then loaded"
			elif [ -e "/lib/firmware/$_fw" ] || [ -e "/lib/firmware/$_fw.zst" ] ||
				[ -e "/lib/firmware/$_fw.xz" ]; then
				warn "firmware $_fw exists in /lib/firmware but the kernel never loaded it"
			else
				warn "firmware $_fw is not in /lib/firmware (the kernel asked for it)"
			fi
		done
	fi
else
	skip "dmesg not available (or sudo -n does not work): failed firmware loads not read"
fi

# ---------------------------------------------------------------------------
section "Storage"
# ---------------------------------------------------------------------------
_root_src="$(findmnt -n -o SOURCE / 2>/dev/null)"
_root_uuid="$(findmnt -n -o UUID / 2>/dev/null)"
info "root    $_root_src (UUID $_root_uuid)"

_fstab_uuid="$(awk '$2 == "/" { print $1 }' /etc/fstab 2>/dev/null | sed -n 's/^UUID=//p')"
if [ -z "$_root_uuid" ] && have blkid; then
	_root_uuid="$(blkid -s UUID -o value "$_root_src" 2>/dev/null)"
fi
if [ -z "$_fstab_uuid" ]; then
	fail "/etc/fstab has no UUID= entry for /"
elif [ -z "$_root_uuid" ]; then
	skip "/etc/fstab not compared: the root UUID could not be read"
elif [ "$_fstab_uuid" = "$_root_uuid" ]; then
	ok "/etc/fstab matches the mounted root"
else
	fail "/etc/fstab root UUID ($_fstab_uuid) != mounted root ($_root_uuid): the next boot will fail"
fi

_swap="$(swapon --show=NAME --noheadings 2>/dev/null || true)"
[ -n "$_swap" ] || _swap="$(awk 'NR > 1 { print $1 }' /proc/swaps 2>/dev/null || true)"
if [ -n "$_swap" ]; then
	ok "swap active: $(printf '%s' "$_swap" | tr '\n' ' ')"
else
	warn "no swap active (systemd-zram-generator should provide /dev/zram0)"
fi

_boot_fstab="$(awk '$2 == "/boot" || $2 == "/boot/efi" { print $1 " " $2; exit }' /etc/fstab 2>/dev/null)"
if [ -n "$_boot_fstab" ]; then
	_boot_spec="${_boot_fstab%% *}"
	_boot_mp="${_boot_fstab#* }"
	_boot_uuid_exp="${_boot_spec#UUID=}"
	_boot_src="$(findmnt -n -o SOURCE "$_boot_mp" 2>/dev/null || true)"
	_boot_uuid="$(findmnt -n -o UUID "$_boot_mp" 2>/dev/null || true)"
	[ -n "$_boot_uuid" ] && [ -n "$_boot_src" ] ||
		_boot_uuid="$(blkid -s UUID -o value "$_boot_src" 2>/dev/null || true)"
	if ! mountpoint -q "$_boot_mp"; then
		fail "/etc/fstab mounts $_boot_mp but it is not mounted"
	elif [ -n "$_boot_uuid" ] && [ "$_boot_uuid" = "$_boot_uuid_exp" ]; then
		ok "$_boot_mp is a separate filesystem ($_boot_src) matching /etc/fstab"
	else
		fail "$_boot_mp UUID mismatch: fstab $_boot_uuid_exp, mounted ${_boot_uuid:-unknown}"
	fi
else
	warn "/etc/fstab has no /boot or /boot/efi entry"
fi

if [ -f "/boot/vmlinuz-$(uname -r)" ]; then
	ok "the running kernel's vmlinuz is on /boot"
else
	fail "/boot/vmlinuz-$(uname -r) is missing: /boot does not hold the running kernel"
fi

_used="$(df -P / | awk 'NR == 2 { print $5 }' | tr -d '%')"
if [ -n "$_used" ] && [ "$_used" -ge 90 ]; then
	warn "root filesystem ${_used}% full"
else
	ok "root filesystem ${_used}% used"
fi

# ---------------------------------------------------------------------------
section "Display & Backlight"
# ---------------------------------------------------------------------------
_connected=""
for _s in /sys/class/drm/card*-*/status; do
	[ -r "$_s" ] || continue
	[ "$(cat "$_s")" = connected ] && _connected="$(basename "$(dirname "$_s")")"
done
if [ -n "$_connected" ]; then
	ok "display connected on $_connected"
else
	fail "no connected DRM connector"
fi

_bl=""
for _b in /sys/class/backlight/*/brightness; do
	[ -e "$_b" ] || continue
	_bl="$_b"
	_mode="$(stat -c %a "$_b")"
	_grp="$(stat -c %G "$_b")"
	if [ "$_grp" = video ] && [ "${_mode: -2:1}" -ge 6 ]; then
		ok "backlight writable by group video ($_mode $_grp)"
	else
		fail "$_b is $_mode $_grp: brightnessctl will fail with Permission denied"
	fi
done
[ -n "$_bl" ] || info "no backlight sysfs node (external monitor / headless)"
if [ "$(id -u)" -ne 0 ]; then
	_groups="$(id -nG 2>/dev/null || true)"
	if grep -qw video <<<"$_groups"; then
		ok "session user is in group video"
	else
		fail "session user is not in group video: brightnessctl cannot write the backlight"
	fi
fi

# ---------------------------------------------------------------------------
section "Input"
# ---------------------------------------------------------------------------
if [ -r /proc/bus/input/devices ]; then
	_kb="$(grep -cE '^H: Handlers=.*kbd' /proc/bus/input/devices || true)"
	_pt="$(grep -cE '^B: ABS=[0-9a-f]*[1-9a-f]' /proc/bus/input/devices || true)"
	[ "${_kb:-0}" -ge 1 ] && ok "$_kb keyboard device(s)" || fail "no keyboard device"
	[ "${_pt:-0}" -ge 1 ] && ok "$_pt pointer/touch device(s)" ||
		fail "no pointer or touchscreen device (absolute-axis input)"
else
	skip "/proc/bus/input/devices not available"
fi

# ---------------------------------------------------------------------------
section "Network"
# ---------------------------------------------------------------------------
if have iw; then
	if [ "$PRIV" != yes ]; then
		skip "iw needs root and sudo -n does not work: the wireless interface is not read"
	else
		_ifaces="$(asroot iw dev 2>/dev/null | awk '/Interface/ {print $2}')"
		if [ -n "$_ifaces" ]; then
			ok "wireless interface: $(printf '%s' "$_ifaces" | tr '\n' ' ')"
		else
			warn "no wireless interface reported by iw dev"
		fi
		_reg="$(asroot iw reg get 2>/dev/null | sed -n 's/^country \([^:]*\).*/\1/p' | head -1)"
		_regdb_bad="$(asroot dmesg 2>/dev/null | grep -c 'failed to load regulatory.db' || true)"
		if [ "${_regdb_bad:-0}" -gt 0 ]; then
			warn "cfg80211 could not load regulatory.db (package wireless-regdb): the world domain cannot change"
		elif [ -z "$_reg" ] || [ "$_reg" = 00 ]; then
			info "regulatory domain: world (country 00), set once NetworkManager or the AP provides one"
		else
			ok "regulatory domain: $_reg"
		fi
	fi
else
	skip "iw is not installed"
fi

check_svc NetworkManager "NetworkManager is active ($(nmcli -t -f STATE,CONNECTIVITY g 2>/dev/null || true))"
_profiles="$(nmcli -t -f NAME,TYPE con show 2>/dev/null | grep -c ':802-11-wireless' || true)"
[ "${_profiles:-0}" -eq 0 ] &&
	_profiles="$(ls /etc/NetworkManager/system-connections/*.nmconnection 2>/dev/null | wc -l)"
[ "${_profiles:-0}" -ge 1 ] && ok "$_profiles Wi-Fi profile(s) installed" ||
	warn "no Wi-Fi profile imported (scripts/wifi.sh import)"
if grep -rqs '^interface-name=' /etc/NetworkManager/system-connections/ 2>/dev/null; then
	warn "a Wi-Fi profile still pins interface-name= (scripts/wifi.sh import strips it)"
elif [ "${_profiles:-0}" -ge 1 ]; then
	ok "no Wi-Fi profile pins an interface name"
fi
have nmtui && ok "nmtui present" || warn "nmtui missing (package network-manager-tui)"
_missing_net=""
for _c in ip ping ss; do have "$_c" || _missing_net="$_missing_net $_c"; done
if [ -z "$_missing_net" ]; then
	ok "network diagnostics present (ip, ping, ss)"
else
	fail "network diagnostics missing:$_missing_net"
fi
if systemctl is-enabled ssh >/dev/null 2>&1; then
	if systemctl is-active ssh >/dev/null 2>&1; then
		info "remote login is enabled (ssh)"
	else
		warn "ssh is enabled but not running: remote login does not answer"
	fi
fi

# ---------------------------------------------------------------------------
section "Bluetooth"
# ---------------------------------------------------------------------------
if have bluetoothctl; then
	if [ "$PRIV" != yes ]; then
		skip "bluetoothctl needs root and sudo -n does not work: the controller is not read"
	else
		_show="$(asroot bluetoothctl show 2>/dev/null || true)"
		info "controller $(printf '%s\n' "$_show" | grep -m1 'Controller' | cut -d' ' -f2-)"
		case "$_show" in
			*"Powered: yes"*) ok "controller powered" ;;
			*) fail "controller is not powered (bluetoothd? firmware?)" ;;
		esac
		have btmgmt && info "btmgmt: $(asroot btmgmt info 2>/dev/null | grep -m1 'current settings' | sed 's/^ *//')"
	fi
else
	skip "bluetoothctl is not installed (package bluez)"
fi

# ---------------------------------------------------------------------------
section "Suspend and power"
# ---------------------------------------------------------------------------
grep -qw mem /sys/power/state 2>/dev/null && ok "/sys/power/state advertises suspend ($(cat /sys/power/state))" ||
	fail "no 'mem' in /sys/power/state: the kernel cannot suspend"
check_svc systemd-logind "systemd-logind is active"
check_svc polkit "polkitd is active"
if [ "$PRIV" != yes ]; then
	skip "journalctl needs sudo -n here: the suspend cycles this boot are not read"
else
	_susp="$(asroot journalctl -b --no-pager 2>/dev/null | grep -c 'PM: suspend entry' || true)"
	[ "${_susp:-0}" -ge 1 ] && ok "$_susp suspend/resume cycle(s) recorded in this boot" ||
		info "no suspend recorded yet in this boot"
fi

# ---------------------------------------------------------------------------
section "System tuning"
# ---------------------------------------------------------------------------
_govs="$(cat /sys/devices/system/cpu/cpufreq/policy*/scaling_governor 2>/dev/null | sort -u | tr '\n' ' ')"
case "$_govs" in
	"schedutil ") ok "cpufreq governor is schedutil on every policy" ;;
	"") skip "no cpufreq scaling_governor sysfs nodes" ;;
	*) warn "cpufreq governor is '${_govs% }', not schedutil" ;;
esac

if [ -r /sys/kernel/mm/lru_gen/enabled ]; then
	_lru="$(cat /sys/kernel/mm/lru_gen/enabled)"
	case "$_lru" in
		0x0000) fail "MGLRU is built in but disabled (lru_gen/enabled=$_lru)" ;;
		*) ok "MGLRU enabled ($_lru)" ;;
	esac
else
	fail "no /sys/kernel/mm/lru_gen: the kernel was built without CONFIG_LRU_GEN"
fi

_thp="$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null)"
case "$_thp" in
	*'[madvise]'*) ok "transparent hugepages: madvise" ;;
	*) warn "transparent hugepages: ${_thp:-unknown} (expected [madvise])" ;;
esac

case "$(cat /proc/swaps 2>/dev/null)" in
	*/dev/zram0*) ok "swap is zram ($(awk '/zram0/ { print $4 " kB in use"; exit }' /proc/swaps))" ;;
	*) fail "no zram swap: memory pressure has nowhere to go" ;;
esac
case "$(systemctl list-units --all --no-legend 'dev-zram0.swap' 2>/dev/null)" in
	*dev-zram0.swap*) ok "zram swap is a systemd unit (systemd-oomd can manage it)" ;;
	*) warn "zram swap is not a dev-zram0.swap unit: systemd-oomd cannot manage it" ;;
esac

_zrc=/etc/systemd/zram-generator.conf
if [ -r "$_zrc" ]; then
	_zrsize=$(awk -F= '/^[[:space:]]*zram-size[[:space:]]*=/ { gsub(/[[:space:]]/, "", $2); print $2; exit }' "$_zrc")
	case $_zrsize in
	ram/2|min\(ram/2,4096\)) ok "zram-size = $_zrsize (half of RAM)" ;;
	"") warn "$_zrc sets no zram-size" ;;
	*) warn "zram-size = $_zrsize, not half of RAM" ;;
	esac
	if grep -qs '^[[:space:]]*zram-resident-limit' "$_zrc"; then
		warn "$_zrc sets zram-resident-limit (can cause premature BLK_STS_IOERR)"
	fi
else
	warn "no $_zrc"
fi
if [ -r /sys/block/zram0/disksize ]; then
	_zdisk=$(($(cat /sys/block/zram0/disksize) / 1024 / 1024))
	_zmem=$(($(awk '/^MemTotal:/ { print $2 }' /proc/meminfo) / 1024))
	_zwant=$((_zmem / 2))
	[ "$_zwant" -gt 4096 ] && _zwant=4096
	if [ "$_zdisk" -ge $((_zwant * 9 / 10)) ] && [ "$_zdisk" -le $((_zwant * 11 / 10)) ]; then
		ok "zram device is $_zdisk MiB, half of RAM"
	elif [ "$_zdisk" -lt $((_zwant * 9 / 10)) ]; then
		warn "zram device is $_zdisk MiB, under half of RAM (~$_zwant MiB)"
	else
		ok "zram device is $_zdisk MiB (~$_zwant MiB target)"
	fi
fi

check_svc systemd-oomd "systemd-oomd is active (kills a hog on memory pressure)"

[ "$(cat /proc/sys/vm/swappiness 2>/dev/null || echo 0)" -ge 100 ] &&
	ok "vm.swappiness=$(cat /proc/sys/vm/swappiness)" ||
	warn "vm.swappiness=$(cat /proc/sys/vm/swappiness): too low for zram"
[ "$(cat /proc/sys/vm/page-cluster 2>/dev/null || echo 3)" -eq 0 ] &&
	ok "vm.page-cluster=0" ||
	warn "vm.page-cluster=$(cat /proc/sys/vm/page-cluster 2>/dev/null): expected 0"
[ "$(cat /proc/sys/vm/watermark_boost_factor 2>/dev/null || echo 1)" -eq 0 ] &&
	ok "vm.watermark_boost_factor=0" ||
	warn "vm.watermark_boost_factor=$(cat /proc/sys/vm/watermark_boost_factor 2>/dev/null): expected 0"
[ "$(cat /proc/sys/vm/vfs_cache_pressure 2>/dev/null || echo 0)" -ge 100 ] &&
	ok "vm.vfs_cache_pressure=$(cat /proc/sys/vm/vfs_cache_pressure)" ||
	warn "vm.vfs_cache_pressure=$(cat /proc/sys/vm/vfs_cache_pressure): expected >= 100"

_cfg="$(ls -1 /boot/config-* 2>/dev/null | head -1)"
if [ -r "$_cfg" ]; then
	_missing_cfg=""
	[ -n "$(grep -x 'CONFIG_HZ=1000' "$_cfg" 2>/dev/null)" ] || _missing_cfg="$_missing_cfg HZ=1000"
	[ -n "$(grep -x 'CONFIG_LRU_GEN=y' "$_cfg" 2>/dev/null)" ] || _missing_cfg="$_missing_cfg LRU_GEN"
	[ -n "$(grep -x 'CONFIG_CPU_FREQ_DEFAULT_GOV_SCHEDUTIL=y' "$_cfg" 2>/dev/null)" ] || _missing_cfg="$_missing_cfg governor=schedutil"
	[ -z "$_missing_cfg" ] && ok "kernel config carries the tuning ($(basename "$_cfg"))" ||
		warn "kernel config lacks:$_missing_cfg"
else
	skip "no /boot/config-* to check the kernel options against"
fi

# ---------------------------------------------------------------------------
section "Clock"
# ---------------------------------------------------------------------------
if have timedatectl; then
	info "$(timedatectl show -p Timezone --value 2>/dev/null) / local RTC $(timedatectl show -p LocalRTC --value 2>/dev/null)"
	[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = yes ] && ok "clock synchronised" ||
		warn "clock not synchronised (systemd-timesyncd needs network)"
else
	skip "timedatectl is not installed"
fi

if [ "$_STANDALONE_CORE" = 1 ]; then
	printf '\n%s==> Summary%s  %d OK, %d WARN, %d FAIL\n' "$C_HEAD" "$C_OFF" "$PASS" "$WARN" "$FAIL"
	[ "$FAIL" -eq 0 ] || exit 1
fi
