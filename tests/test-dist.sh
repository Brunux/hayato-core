#!/bin/bash
# Unit tests for scripts/lib-dist.sh: what a published artifact must not carry.
# The sanitizer runs against a throwaway tree; `install -o root` is shimmed so
# the suite works unprivileged, which is how CI runs it.
set -u
cd "$(dirname "$0")/.." || exit 1
. tests/harness.sh

ROOT="$(pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

WORK_DIR="$TMP/work"
ROOTFS="$TMP/rootfs"
mkdir -p "$WORK_DIR" "$ROOTFS/etc/NetworkManager/system-connections"

die() {
	printf '[fail] %s\n' "$*" >&2
	exit 1
}
log() { :; }
warn() { printf '[warn] %s\n' "$*" >&2; }
# The rejection cases run lib-dist.sh in a child bash; exported functions keep
# its helpers (and the test's silent log) available there.
export -f log warn die

# shellcheck disable=SC1091
. "$ROOT/scripts/lib-dist.sh"

# dist_sanitize installs root-owned directories; a test user cannot. Strip the
# ownership flags and keep the mode, which is what the assertions read.
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

# --- the exclude list ------------------------------------------------------
EXCLUDES="$TMP/excludes.txt"
dist_write_excludes "$EXCLUDES"
assert_true "the exclude file is written" test -s "$EXCLUDES"
assert_false "the exclude file has no blank lines" grep -qx '' "$EXCLUDES"
for pattern in \
	'/boot/efi' \
	'/etc/NetworkManager/system-connections/' \
	'/var/lib/NetworkManager/' \
	'/etc/ssh/ssh_host_*' \
	'/etc/machine-id' \
	'/home/*/.local/share/opencode/' \
	'/home/*/.config/opencode/'; do
	assert_true "excludes $pattern" grep -qxF "$pattern" "$EXCLUDES"
done

# --- dist_sanitize removes the maintainer's state -------------------------
SAN="$TMP/sanitize"
mkdir -p \
	"$SAN/etc/NetworkManager/system-connections" \
	"$SAN/var/lib/NetworkManager" \
	"$SAN/etc/ssh" \
	"$SAN/etc/lazyos" \
	"$SAN/var/lib/lazyos/greeter" \
	"$SAN/var/lib/dbus" \
	"$SAN/root/.ssh" \
	"$SAN/home/b/.cache/debian-aarch64" \
	"$SAN/home/b/.local/share/opencode" \
	"$SAN/home/b/.local/state/opencode" \
	"$SAN/home/b/.cache/opencode" \
	"$SAN/home/b/.config/opencode" \
	"$SAN/var/log/journal" \
	"$SAN/tmp/repo"
printf '[wifi]\npsk=secret\n' >"$SAN/etc/NetworkManager/system-connections/home.nmconnection"
printf 'state\n' >"$SAN/var/lib/NetworkManager/NetworkManager.state"
printf 'key\n' >"$SAN/etc/ssh/ssh_host_ed25519_key"
printf 'machine\n' >"$SAN/etc/machine-id"
printf 'machine\n' >"$SAN/var/lib/dbus/machine-id"
printf 'installed\n' >"$SAN/etc/lazyos/installation"
printf 'state\n' >"$SAN/var/lib/lazyos/greeter/state.toml"
printf 'key\n' >"$SAN/root/.ssh/id_ed25519"
printf 'cache\n' >"$SAN/home/b/.cache/debian-aarch64/profile"
printf 'db\n' >"$SAN/home/b/.local/share/opencode/opencode.db"
printf 'db\n' >"$SAN/home/b/.local/state/opencode/state.db"
printf 'db\n' >"$SAN/home/b/.cache/opencode/cache.db"
printf '{}\n' >"$SAN/home/b/.config/opencode/opencode.json"
printf 'log\n' >"$SAN/var/log/bootstrap.log"
printf 'repo\n' >"$SAN/tmp/repo/file"

dist_sanitize "$SAN"

assert_false "Wi-Fi profiles are gone" test -e "$SAN/etc/NetworkManager/system-connections/home.nmconnection"
assert_true "the profile directory is recreated" test -d "$SAN/etc/NetworkManager/system-connections"
assert_eq "700" "$(stat -c %a "$SAN/etc/NetworkManager/system-connections")" \
	"the profile directory is 0700"
assert_false "NetworkManager state is gone" test -e "$SAN/var/lib/NetworkManager/NetworkManager.state"
assert_true "the NetworkManager state directory is recreated" test -d "$SAN/var/lib/NetworkManager"
assert_false "SSH host keys are gone" test -e "$SAN/etc/ssh/ssh_host_ed25519_key"
assert_true "machine-id exists and is empty" test -f "$SAN/etc/machine-id"
assert_eq "" "$(cat "$SAN/etc/machine-id")" "machine-id is emptied, not deleted"
assert_false "the dbus machine-id is gone" test -e "$SAN/var/lib/dbus/machine-id"
assert_false "the installation marker is gone" test -e "$SAN/etc/lazyos/installation"
assert_false "the greeter state is gone" test -e "$SAN/var/lib/lazyos/greeter/state.toml"
assert_false "root's SSH directory is gone" test -e "$SAN/root/.ssh"
assert_false "the build cache is gone" test -e "$SAN/home/b/.cache/debian-aarch64"
assert_false "the OpenCode database is gone" test -e "$SAN/home/b/.local/share/opencode"
assert_false "the OpenCode state is gone" test -e "$SAN/home/b/.local/state/opencode"
assert_false "the OpenCode cache is gone" test -e "$SAN/home/b/.cache/opencode"
assert_false "the OpenCode config is gone" test -e "$SAN/home/b/.config/opencode"
assert_false "the bootstrap log is gone" test -e "$SAN/var/log/bootstrap.log"
assert_false "the copied repository is gone" test -e "$SAN/tmp/repo"

# --- dist_assert_clean accepts a clean tree and rejects each leak ---------
CLEAN="$TMP/clean"
mkdir -p "$CLEAN/etc/ssh" "$CLEAN/etc/lazyos" "$CLEAN/root" "$CLEAN/home/b"
: >"$CLEAN/etc/machine-id"

expect_status 0 "a clean tree passes dist_assert_clean" \
	bash -c "ROOTFS='$ROOTFS' WORK_DIR='$WORK_DIR' . '$ROOT/scripts/lib-dist.sh'; dist_assert_clean '$CLEAN'"

reject_n=0
check_rejected() {
	local what="$1" setup="$2"
	local tree
	reject_n=$((reject_n + 1))
	tree="$TMP/reject-$reject_n"
	cp -a "$CLEAN" "$tree"
	setup="${setup//__TREE__/$tree}"
	eval "$setup"
	expect_status 1 "$what" \
		bash -c "ROOTFS='$ROOTFS' WORK_DIR='$WORK_DIR' . '$ROOT/scripts/lib-dist.sh'; dist_assert_clean '$tree'"
}

check_rejected "a Wi-Fi profile is rejected" "mkdir -p '__TREE__/etc/NetworkManager/system-connections'; printf x >'__TREE__/etc/NetworkManager/system-connections/a.nmconnection'"
check_rejected "a DHCP lease is rejected" "printf x >'__TREE__/var.lease'"
check_rejected "an SSH host key is rejected" "printf x >'__TREE__/etc/ssh/ssh_host_rsa_key'"
check_rejected "a non-empty machine-id is rejected" "printf x >'__TREE__/etc/machine-id'"
check_rejected "a dbus machine-id is rejected" "mkdir -p '__TREE__/var/lib/dbus'; printf x >'__TREE__/var/lib/dbus/machine-id'"
check_rejected "an installation marker is rejected" "printf x >'__TREE__/etc/lazyos/installation'"
check_rejected "a non-empty root SSH directory is rejected" "mkdir -p '__TREE__/root/.ssh'; printf x >'__TREE__/root/.ssh/id'"
check_rejected "a non-empty OpenCode database is rejected" "mkdir -p '__TREE__/home/b/.local/share/opencode'; printf x >'__TREE__/home/b/.local/share/opencode/db'"

# An empty directory is the state sanitize leaves behind, so it must pass.
mkdir -p "$CLEAN/root/.ssh" "$CLEAN/home/b/.cache/debian-aarch64" \
	"$CLEAN/home/b/.local/share/opencode"
expect_status 0 "empty leftover directories still pass dist_assert_clean" \
	bash -c "ROOTFS='$ROOTFS' WORK_DIR='$WORK_DIR' . '$ROOT/scripts/lib-dist.sh'; dist_assert_clean '$CLEAN'"

# --- dist_assert_no_profile_bytes searches the artifact's bytes -----------
PROFILE_ROOTFS="$TMP/profile-rootfs"
mkdir -p "$PROFILE_ROOTFS/etc/NetworkManager/system-connections"
printf '[wifi]\npsk=supersecret123\n' \
	>"$PROFILE_ROOTFS/etc/NetworkManager/system-connections/HomeNet.nmconnection"

ARTIFACT_CLEAN="$TMP/artifact-clean"
mkdir -p "$ARTIFACT_CLEAN"
printf 'ordinary image bytes\n' >"$ARTIFACT_CLEAN/blob"

expect_status 0 "an artifact without the profile passes the byte check" \
	bash -c "ROOTFS='$PROFILE_ROOTFS' WORK_DIR='$WORK_DIR' . '$ROOT/scripts/lib-dist.sh'; dist_assert_no_profile_bytes '$ARTIFACT_CLEAN'"

ARTIFACT_LEAK="$TMP/artifact-leak"
mkdir -p "$ARTIFACT_LEAK"
printf 'free space still holds supersecret123\n' >"$ARTIFACT_LEAK/blob"

out="$(ROOTFS="$PROFILE_ROOTFS" WORK_DIR="$WORK_DIR" bash -c \
	". '$ROOT/scripts/lib-dist.sh'; dist_assert_no_profile_bytes '$ARTIFACT_LEAK'" 2>&1)"
status=$?
assert_eq "1" "$status" "an artifact carrying the PSK is rejected"
assert_contains "$out" "Wi-Fi credentials" "the refusal explains the leaked bytes"

EMPTY_ROOTFS="$TMP/empty-rootfs"
mkdir -p "$EMPTY_ROOTFS/etc/NetworkManager/system-connections"
expect_status 0 "no profiles means nothing to look for" \
	bash -c "ROOTFS='$EMPTY_ROOTFS' WORK_DIR='$WORK_DIR' . '$ROOT/scripts/lib-dist.sh'; dist_assert_no_profile_bytes '$ARTIFACT_LEAK'"

finish
