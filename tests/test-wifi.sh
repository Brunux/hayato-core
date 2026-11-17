#!/bin/bash
# Unit tests for scripts/wifi.sh: profile import/export and the interface-name
# rewrite. The script is sourced (its command dispatch is guarded), so the
# helpers are driven directly against throwaway directories.
set -u
cd "$(dirname "$0")/.." || exit 1
. tests/harness.sh

ROOT="$(pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Source the command without needing a devices checkout or root, and replace
# the two privileged calls with no-ops.
load_wifi() {
	export BUILD_ROOT="$TMP/build"
	export LAZYOS_ALLOW_NO_DEVICE=1
	unset DEVICE DEVICE_DIR
	# shellcheck disable=SC1091
	. "$ROOT/scripts/wifi.sh"
	set +euo pipefail
	need_root() { :; }
	chown() { :; }
	install() {
		local -a args=()
		while [ "$#" -gt 0 ]; do
			case "$1" in
			-o | -g) shift 2 ;;
			*) args+=("$1"); shift ;;
			esac
		done
		command install "${args[@]}"
	}
}

# --- list_profiles prints one path per line, spaces included --------------
SRC="$TMP/src"
mkdir -p "$SRC" "$TMP/empty"
printf '[connection]\nid=Home\npsk=one\n' >"$SRC/Home Net.nmconnection"
printf '[connection]\nid=Cafe\npsk=two\n' >"$SRC/Cafe.nmconnection"
printf 'not a profile\n' >"$SRC/notes.txt"

(
	load_wifi
	listing="$(list_profiles "$SRC")"
	assert_eq "$(printf '%s\n' "$SRC/Cafe.nmconnection" "$SRC/Home Net.nmconnection")" \
		"$(printf '%s\n' "$listing" | sort)" \
		"list_profiles returns each profile, spaces preserved"
	assert_eq "2" "$(printf '%s\n' "$listing" | wc -l | tr -d ' ')" \
		"only *.nmconnection files are listed"
)

(
	load_wifi
	expect_status 1 "an empty directory is refused" list_profiles "$TMP/empty"
	expect_status 1 "a missing directory is refused" list_profiles "$TMP/no-such-dir"
)

# --- import copies profiles, drops interface-name and sets 0600 -----------
IMPORT_SRC="$TMP/import-src"
IMPORT_DEST="$TMP/import-dest"
mkdir -p "$IMPORT_SRC" "$IMPORT_DEST"
printf '[connection]\nid=Home\ninterface-name=wlan0\npsk=secret\n' \
	>"$IMPORT_SRC/Home Net.nmconnection"
printf '[connection]\nid=Cafe\npsk=two\n' >"$IMPORT_SRC/Cafe.nmconnection"
cp "$IMPORT_SRC/Home Net.nmconnection" "$TMP/original-profile"

(
	load_wifi
	do_import "$IMPORT_SRC" "$IMPORT_DEST"
	target="$IMPORT_DEST/etc/NetworkManager/system-connections"
	assert_true "the profile directory is created" test -d "$target"
	assert_true "a profile with a space in its name is imported" \
		test -f "$target/Home Net.nmconnection"
	assert_not_contains "$(cat "$target/Home Net.nmconnection")" "interface-name=" \
		"import drops interface-name so NetworkManager binds any device"
	assert_contains "$(cat "$target/Home Net.nmconnection")" "psk=secret" \
		"import keeps the rest of the profile"
	assert_contains "$(cat "$target/Cafe.nmconnection")" "id=Cafe" \
		"a profile without interface-name is copied unchanged"
	assert_eq "600" "$(stat -c %a "$target/Home Net.nmconnection")" \
		"an imported profile is readable by root only"
	assert_eq "" "$(find "$target" -maxdepth 1 -name '.*.tmp' -print)" \
		"no temporary file is left behind"
	assert_eq "$(cat "$TMP/original-profile")" "$(cat "$IMPORT_SRC/Home Net.nmconnection")" \
		"the source profile is not modified"
)

# --- export copies profiles into WIFI_DIR with 0600 ------------------------
(
	load_wifi
	WIFI_DIR="$TMP/exported"
	do_export "$IMPORT_SRC"
	assert_true "export creates the Wi-Fi directory" test -d "$WIFI_DIR"
	assert_true "export copies every profile" test -f "$WIFI_DIR/Cafe.nmconnection"
	assert_eq "600" "$(stat -c %a "$WIFI_DIR/Cafe.nmconnection")" \
		"an exported profile is readable by root only"
	assert_eq "$(cat "$IMPORT_SRC/Cafe.nmconnection")" \
		"$(cat "$WIFI_DIR/Cafe.nmconnection")" \
		"export copies the profile byte for byte"
)

(
	load_wifi
	WIFI_DIR="$TMP/exported-empty"
	expect_status 1 "export refuses a source with no profiles" do_export "$TMP/empty"
)

finish
