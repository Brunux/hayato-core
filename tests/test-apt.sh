#!/bin/bash
# Unit tests for scripts/hayato-apt.sh and scripts/build-core-deb.sh.
set -u
cd "$(dirname "$0")/.." || exit 1
. tests/harness.sh

ROOT="$(pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- hayato-apt status reads the DEB822 source and keyring ----------------
SRC_FILE="$TMP/hayato.sources"
KEY_FILE="$TMP/hayato-archive-keyring.gpg"
cp "$ROOT/apt/hayato.sources" "$SRC_FILE"
cp "$ROOT/apt/hayato-archive-keyring.gpg" "$KEY_FILE"

out="$(HAYATO_APT_SOURCES_FILE="$SRC_FILE" HAYATO_APT_KEYRING_FILE="$KEY_FILE" \
	bash "$ROOT/scripts/hayato-apt.sh" status)"
assert_contains "$out" "enabled=no" "default Cloudsmith source starts disabled until enabled"
assert_contains "$out" "uri=https://dl.cloudsmith.io/public/hayato/hayato/deb/debian" "default URI points to Cloudsmith"
assert_contains "$out" "suite=forky" "default suite is forky"
assert_contains "$out" "keyring=present" "committed GPG keyring is detected"

# --- build-core-deb.sh produces hayato-core.deb and hayato-apt build-repo indexes it ---
if command -v dpkg-deb >/dev/null 2>&1; then
	export BUILD_ROOT="$TMP/build"
	export HAYATO_ALLOW_NO_DEVICE=1
	REPO_DIR="$TMP/apt-repo"
	mkdir -p "$REPO_DIR"

	bash "$ROOT/scripts/build-core-deb.sh" "$REPO_DIR" >/dev/null
	cdeb="$(ls "$REPO_DIR"/hayato-core_*.deb 2>/dev/null | head -n1)"
	assert_true "hayato-core .deb is built" test -f "$cdeb"
	assert_contains "$(dpkg-deb -c "$cdeb")" "./etc/kernel/postinst.d/zz-hayato-boot" \
		"hayato-core .deb ships kernel postinst hook"
	assert_contains "$(dpkg-deb -c "$cdeb")" "./etc/initramfs/post-update.d/zz-hayato-boot" \
		"hayato-core .deb ships initramfs post-update hook"
	assert_contains "$(dpkg-deb -c "$cdeb")" "./usr/sbin/hayato-apt" \
		"hayato-core .deb ships hayato-apt in /usr/sbin (sudo PATH)"
	assert_contains "$(dpkg-deb -c "$cdeb")" "./usr/share/keyrings/hayato-archive-keyring.gpg" \
		"hayato-core .deb ships the APT archive keyring"

	bash "$ROOT/scripts/hayato-apt.sh" build-repo "$REPO_DIR" >/dev/null
	assert_true "Packages index is generated" test -s "$REPO_DIR/Packages"
	assert_true "Packages.gz index is generated" test -s "$REPO_DIR/Packages.gz"
	assert_true "Release file is generated" test -s "$REPO_DIR/Release"
	assert_contains "$(cat "$REPO_DIR/Packages")" "Package: hayato-core" \
		"Packages index lists hayato-core"
	assert_contains "$(cat "$REPO_DIR/Release")" "Suite: forky" \
		"Release metadata targets forky"

	# Dry-run upgrade-from-github against a local directory with SHA256SUMS
	(
		cd "$REPO_DIR"
		sha256sum *.deb >SHA256SUMS
	)
	up_out="$(bash "$ROOT/scripts/hayato-apt.sh" upgrade-from-github --dir "$REPO_DIR" --dry-run)"
	assert_contains "$up_out" "hayato-core_" "upgrade-from-github matches hayato-core .deb"
fi

finish
