#!/bin/bash
# Modular health report for LazyOS (dispatches core, device, and desktop witnesses).
#
# Usage:
#   check-system.sh [REPO_OR_UMBRELLA_DIR]
#   check-system.sh --summary [REPO_OR_UMBRELLA_DIR]
#   check-system.sh --help
#
# Works both on a live system (from /usr/libexec/lazyos/check/{10-core,20-device,30-desktop}.sh)
# and against an umbrella or sibling development checkout.
set -u

SUMMARY_ONLY=0
for arg in "$@"; do
	case "$arg" in
		--help|-h)
			sed -n '2,9p' "$0" | cut -c3-
			exit 0
			;;
		--summary)
			SUMMARY_ONLY=1
			shift
			;;
	esac
done

_self="$(cd "$(dirname "$0")" && pwd)"

if [ "$(id -u)" -eq 0 ] && [ -z "${_CHECK_SYSTEM_REEXEC:-}" ]; then
	for _p in /run/user/*; do
		_uid="${_p##*/}"
		[ -S "$_p/wayland-0" ] || continue
		_user="$(id -nu "$_uid" 2>/dev/null || true)"
		[ -n "$_user" ] || continue
		exec env _CHECK_SYSTEM_REEXEC=1 su - "$_user" -c \
			"XDG_RUNTIME_DIR='$_p' WAYLAND_DISPLAY=wayland-0 $(printf '%q ' "$0" "$@")"
	done
fi

REPO="${1:-$(cd "$_self/.." 2>/dev/null && pwd)}"
CORE_REPO=""
DEVICES_REPO=""
DESKTOP_REPO=""

for _cand in "${LAZYOS_CORE_DIR:-}" "$REPO/core" "$REPO" "$_self/.." "$_self/../../lazyos-core"; do
	[ -n "$_cand" ] && [ -f "$_cand/scripts/check-core.sh" ] && CORE_REPO="$(cd "$_cand" && pwd)" && break
done
for _cand in "${LAZYOS_DEVICES_DIR:-}" "$REPO/devices" "$REPO/../devices" "$REPO/../lazyos-devices" "$_self/../../lazyos-devices"; do
	[ -n "$_cand" ] && [ -d "$_cand/devices" ] && DEVICES_REPO="$(cd "$_cand" && pwd)" && break
done
for _cand in "${LAZYOS_DESKTOP_DIR:-}" "$REPO/desktop" "$REPO" "$REPO/../desktop" "$REPO/../lazyos-desktop" "$_self/../../lazyos-desktop"; do
	[ -n "$_cand" ] && [ -d "$_cand/uis" ] && DESKTOP_REPO="$(cd "$_cand" && pwd)" && break
done

if [ -n "$DESKTOP_REPO" ]; then
	if [ -x "$DESKTOP_REPO/rust/target/release/lazyos" ]; then
		PATH="$DESKTOP_REPO/rust/target/release:$PATH"
	elif [ -x "$DESKTOP_REPO/rust/target/debug/lazyos" ]; then
		PATH="$DESKTOP_REPO/rust/target/debug:$PATH"
	fi
fi

DEVICE="${DEVICE:-$(tr -d ' \t\r\n' </etc/lazyos/device 2>/dev/null || true)}"
[ -n "$DEVICE" ] || DEVICE="google-asurada"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
	C_OK='\033[1;32m' C_WARN='\033[1;33m' C_FAIL='\033[1;31m'
	C_INFO='\033[0;36m' C_DIM='\033[2m' C_HEAD='\033[1;37m' C_OFF='\033[0m'
else
	C_OK="" C_WARN="" C_FAIL="" C_INFO="" C_DIM="" C_HEAD="" C_OFF=""
fi

PASS=0 WARN=0 FAIL=0 SECTION=""
section() { SECTION="$1"; [ "$SUMMARY_ONLY" = 1 ] || printf '\n%s==> %s%s\n' "$C_HEAD" "$1" "$C_OFF"; }
ok()   { PASS=$((PASS + 1)); [ "$SUMMARY_ONLY" = 1 ] || printf "  ${C_OK}%-4s${C_OFF}  %s\n" OK "$*"; }
warn() { WARN=$((WARN + 1)); printf "  ${C_WARN}%-4s${C_OFF}  [%s] %s\n" WARN "$SECTION" "$*"; }
fail() { FAIL=$((FAIL + 1)); printf "  ${C_FAIL}%-4s${C_OFF}  [%s] %s\n" FAIL "$SECTION" "$*"; }
skip() { [ "$SUMMARY_ONLY" = 1 ] || printf "  ${C_DIM}%-4s${C_OFF}  %s\n" SKIP "$*"; }
info() { [ "$SUMMARY_ONLY" = 1 ] || printf "  ${C_INFO}%-4s${C_OFF}  %s\n" INFO "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

PRIV=no
if [ "$(id -u)" -eq 0 ]; then
	asroot() { "$@" 2>/dev/null; }
	PRIV=yes
else
	asroot() { sudo -n "$@" 2>/dev/null; }
	if sudo -n true 2>/dev/null; then
		PRIV=yes
	else
		warn "sudo -n does not work here: privileged reads say SKIP"
	fi
fi

check_svc() {
	local u="$1" desc="${2:-$1 is active}"
	if ! have systemctl; then skip "no systemctl ($u)"; return 0; fi
	if systemctl is-active --quiet "$u" 2>/dev/null; then ok "$desc"
	else warn "$u is not active"; fi
}

SETTINGS_ROWS="$(lazyos menu settings --rows 2>/dev/null || true)"
settings_runs() { awk -F'\t' -v want="$1" '$3 == want { found = 1 } END { exit !found }' <<<"$SETTINGS_ROWS"; }

export _CHECK_SYSTEM_SOURCED=1

_run_hook() {
	local label="$1" installed="$2" fallback="$3"
	if [ -f "$installed" ]; then
		# shellcheck disable=SC1090
		. "$installed"
	elif [ -n "$fallback" ] && [ -f "$fallback" ]; then
		# shellcheck disable=SC1090
		. "$fallback"
	else
		skip "no $label witness installed ($installed)"
	fi
}

_core_fallback="${CORE_REPO:+$CORE_REPO/scripts/check-core.sh}"
_device_fallback="${DEVICES_REPO:+$DEVICES_REPO/devices/$DEVICE/check-device.sh}"
_desktop_fallback="${DESKTOP_REPO:+$DESKTOP_REPO/scripts/check-desktop.sh}"

_run_hook "core"    "/usr/libexec/lazyos/check/10-core.sh"    "$_core_fallback"
_run_hook "device"  "/usr/libexec/lazyos/check/20-device.sh"  "$_device_fallback"
_run_hook "desktop" "/usr/libexec/lazyos/check/30-desktop.sh" "$_desktop_fallback"

# ---------------------------------------------------------------------------
section "Declared packages"
# ---------------------------------------------------------------------------
if have dpkg-query && { [ -n "$CORE_REPO" ] || [ -n "$DESKTOP_REPO" ] || [ -n "$DEVICES_REPO" ]; }; then
	_missing=""
	_count=0
	_pkg_lists=()
	[ -n "$CORE_REPO" ] && for _f in "$CORE_REPO"/packages/*.list; do [ -f "$_f" ] && _pkg_lists+=("$_f"); done
	[ -n "$DESKTOP_REPO" ] && for _f in "$DESKTOP_REPO"/packages/*.list "$DESKTOP_REPO"/uis/*/packages.list; do [ -f "$_f" ] && _pkg_lists+=("$_f"); done
	[ -n "$DEVICES_REPO" ] && [ -f "$DEVICES_REPO/devices/$DEVICE/packages.list" ] && _pkg_lists+=("$DEVICES_REPO/devices/$DEVICE/packages.list")
	for _list in "${_pkg_lists[@]}"; do
		while read -r _pkg; do
			case "$_pkg" in '' | '#'*) continue ;; esac
			_count=$((_count + 1))
			_st="$(dpkg-query -W -f='${Status}' "$_pkg" 2>/dev/null || true)"
			grep -q 'install ok installed' <<<"$_st" || _missing="$_missing $_pkg"
		done <"$_list"
	done
	if [ -z "$_missing" ]; then
		ok "all $_count declared package(s) are installed"
	else
		fail "declared but not installed:$_missing"
	fi
else
	skip "no repository checkout: run check-system.sh <repo> to check declared packages"
fi

# ---------------------------------------------------------------------------
section "Journal"
# ---------------------------------------------------------------------------
if [ "$PRIV" != yes ]; then
	skip "journalctl needs sudo -n here: the error-priority count is not read"
else
	_errs="$(asroot journalctl -b -p err --no-pager 2>/dev/null | grep -vc '^-- No entries --' || true)"
	if [ "${_errs:-0}" -eq 0 ]; then
		ok "no error-priority messages this boot"
	else
		warn "$_errs error-priority line(s) this boot; the last ones:"
		asroot journalctl -b -p err --no-pager 2>/dev/null | tail -6 | sed 's/^/          /'
	fi
fi

printf '\n%s==> Summary%s  %d OK, %d WARN, %d FAIL\n' "$C_HEAD" "$C_OFF" "$PASS" "$WARN" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
