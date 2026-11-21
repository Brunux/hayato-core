#!/bin/bash
# Manage the Hayato APT repository configuration (Cloudsmith + GitHub Releases)
# and generate signed APT repository metadata from staged .deb packages.
#
# Usage:
#   hayato-apt status
#   hayato-apt enable [--repo OWNER/REPO] [--url URI] [--suite SUITE] [--no-update] [--no-fetch-key]
#   hayato-apt disable
#   hayato-apt build-repo <DIR>
#   hayato-apt upgrade-from-github [--repo OWNER/REPO] [--tag TAG] [--dir DIR] [--dry-run]
set -euo pipefail

SOURCES_FILE="${HAYATO_APT_SOURCES_FILE:-/etc/apt/sources.list.d/hayato.sources}"
KEYRING_FILE="${HAYATO_APT_KEYRING_FILE:-/usr/share/keyrings/hayato-archive-keyring.gpg}"
ASC_FILE="${HAYATO_APT_ASC_FILE:-/usr/share/keyrings/hayato-archive-keyring.asc}"
DEFAULT_CLOUDSMITH_REPO="${CLOUDSMITH_REPO:-hayato/hayato}"
DEFAULT_GITHUB_REPO="${HAYATO_GITHUB_REPO:-Brunux/Hayato}"
DEFAULT_SUITE="${DEBIAN_SUITE:-forky}"

log()  { printf '\033[1;34m[hayato-apt]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

need_root_reexec() {
	if [ "$(id -u)" -ne 0 ]; then
		exec sudo -n \
			HAYATO_APT_SOURCES_FILE="$SOURCES_FILE" \
			HAYATO_APT_KEYRING_FILE="$KEYRING_FILE" \
			HAYATO_APT_ASC_FILE="$ASC_FILE" \
			CLOUDSMITH_REPO="$DEFAULT_CLOUDSMITH_REPO" \
			HAYATO_GITHUB_REPO="$DEFAULT_GITHUB_REPO" \
			DEBIAN_SUITE="$DEFAULT_SUITE" \
			"$(readlink -f "$0")" "$@"
	fi
}

usage() {
	sed -n '2,10p' "$0" | cut -c3-
}

cmd_status() {
	local enabled="no" uri="" suite="" keyring="missing"
	if [ -f "$SOURCES_FILE" ]; then
		enabled="$(sed -n 's/^Enabled:[[:space:]]*//p' "$SOURCES_FILE" 2>/dev/null | head -n1 || true)"
		[ -n "$enabled" ] || enabled="yes"
		uri="$(sed -n 's/^URIs:[[:space:]]*//p' "$SOURCES_FILE" 2>/dev/null | head -n1 || true)"
		suite="$(sed -n 's/^Suites:[[:space:]]*//p' "$SOURCES_FILE" 2>/dev/null | head -n1 || true)"
	fi
	if [ -s "$KEYRING_FILE" ]; then
		keyring="present"
	fi
	printf 'enabled=%s\nuri=%s\nsuite=%s\nkeyring=%s\nsources=%s\n' \
		"$enabled" "${uri:-none}" "${suite:-none}" "$keyring" "$SOURCES_FILE"
}

cmd_enable() {
	local repo="$DEFAULT_CLOUDSMITH_REPO"
	local url=""
	local suite="$DEFAULT_SUITE"
	local do_update="yes"
	local fetch_key="yes"
	local orig_args=("enable" "$@")

	while [ "$#" -gt 0 ]; do
		case "$1" in
			--repo) repo="${2:-}"; shift 2 ;;
			--url) url="${2:-}"; shift 2 ;;
			--suite) suite="${2:-}"; shift 2 ;;
			--no-update) do_update="no"; shift ;;
			--no-fetch-key) fetch_key="no"; shift ;;
			*) die "unknown option for enable: $1" ;;
		esac
	done

	need_root_reexec "${orig_args[@]}"

	[ -n "$url" ] || url="https://dl.cloudsmith.io/public/${repo}/deb/debian"
	local arch
	arch="$(dpkg --print-architecture 2>/dev/null || echo arm64)"

	install -d -m 0755 "$(dirname "$SOURCES_FILE")" "$(dirname "$KEYRING_FILE")"

	if [ "$fetch_key" = "yes" ] && command -v curl >/dev/null 2>&1 && command -v gpg >/dev/null 2>&1; then
		local tmp_gpg
		tmp_gpg="$(mktemp -d /tmp/hayato-apt-gpg.XXXXXX)"
		chmod 700 "$tmp_gpg"
		if [ -f "$ASC_FILE" ]; then
			GNUPGHOME="$tmp_gpg" gpg --batch --yes --import "$ASC_FILE" >/dev/null 2>&1 || true
		elif [ -f "$KEYRING_FILE" ]; then
			GNUPGHOME="$tmp_gpg" gpg --batch --yes --import "$KEYRING_FILE" >/dev/null 2>&1 || true
		fi
		if curl -fsSL --connect-timeout 5 "https://dl.cloudsmith.io/public/${repo}/cfg/gpg/gpg.key" -o "$tmp_gpg/cs.key" 2>/dev/null ||
		   curl -fsSL --connect-timeout 5 "${url}/gpg.key" -o "$tmp_gpg/cs.key" 2>/dev/null; then
			GNUPGHOME="$tmp_gpg" gpg --batch --yes --import "$tmp_gpg/cs.key" >/dev/null 2>&1 || true
			log "Merged Cloudsmith signing key for $repo"
		fi
		if GNUPGHOME="$tmp_gpg" gpg --batch --yes --export >"$tmp_gpg/merged.gpg" 2>/dev/null && [ -s "$tmp_gpg/merged.gpg" ]; then
			install -m 0644 "$tmp_gpg/merged.gpg" "$KEYRING_FILE"
		fi
		rm -rf "$tmp_gpg"
	fi

	cat >"$SOURCES_FILE" <<EOF
Types: deb
URIs: $url
Suites: $suite
Components: main
Architectures: $arch
Signed-By: $KEYRING_FILE
Enabled: yes
EOF
	chmod 0644 "$SOURCES_FILE"
	log "Enabled Hayato APT source ($url $suite)"

	if [ "$do_update" = "yes" ]; then
		apt-get update
	fi
}

cmd_disable() {
	need_root_reexec "disable" "$@"
	if [ -f "$SOURCES_FILE" ]; then
		if grep -q '^Enabled:' "$SOURCES_FILE"; then
			sed -i 's/^Enabled:.*/Enabled: no/' "$SOURCES_FILE"
		else
			printf 'Enabled: no\n' >>"$SOURCES_FILE"
		fi
		log "Disabled Hayato APT source ($SOURCES_FILE)"
	fi
}

cmd_build_repo() {
	local dir="${1:-}"
	[ -n "$dir" ] && [ -d "$dir" ] || die "usage: hayato-apt build-repo <DIR>"
	local _here
	_here="$(cd "$(dirname "$0")" && pwd)"
	local _core_dir
	_core_dir="$(cd "$_here/.." && pwd)"

	for _k in hayato-archive-keyring.gpg hayato-archive-keyring.asc; do
		if [ -f "$_core_dir/apt/$_k" ] && [ ! -f "$dir/$_k" ]; then
			cp "$_core_dir/apt/$_k" "$dir/$_k"
		elif [ -f "/usr/share/keyrings/$_k" ] && [ ! -f "$dir/$_k" ]; then
			cp "/usr/share/keyrings/$_k" "$dir/$_k"
		fi
	done

	(
		cd "$dir"
		rm -f Packages Packages.gz Release InRelease Release.gpg
		if command -v apt-ftparchive >/dev/null 2>&1; then
			apt-ftparchive packages . >Packages
		elif command -v dpkg-scanpackages >/dev/null 2>&1; then
			dpkg-scanpackages -m . /dev/null >Packages
		else
			: >Packages
			for deb in *.deb; do
				[ -f "$deb" ] || continue
				dpkg-deb -f "$deb" | sed '/^$/d' >>Packages
				printf 'Filename: ./%s\n' "$deb" >>Packages
				printf 'Size: %s\n' "$(stat -c %s "$deb")" >>Packages
				printf 'SHA256: %s\n\n' "$(sha256sum "$deb" | awk '{print $1}')" >>Packages
			done
		fi
		gzip -9cn Packages >Packages.gz

		if command -v apt-ftparchive >/dev/null 2>&1; then
			apt-ftparchive \
				-o APT::FTPArchive::Release::Origin="Hayato" \
				-o APT::FTPArchive::Release::Label="Hayato" \
				-o APT::FTPArchive::Release::Suite="$DEFAULT_SUITE" \
				-o APT::FTPArchive::Release::Codename="$DEFAULT_SUITE" \
				-o APT::FTPArchive::Release::Architectures="arm64 amd64" \
				-o APT::FTPArchive::Release::Components="main" \
				-o APT::FTPArchive::Release::Description="Hayato Debian repository" \
				release . >Release
		else
			local p_size p_gz_size p_sha p_gz_sha p_md5 p_gz_md5
			p_size="$(stat -c %s Packages)"
			p_gz_size="$(stat -c %s Packages.gz)"
			p_sha="$(sha256sum Packages | awk '{print $1}')"
			p_gz_sha="$(sha256sum Packages.gz | awk '{print $1}')"
			p_md5="$(md5sum Packages | awk '{print $1}')"
			p_gz_md5="$(md5sum Packages.gz | awk '{print $1}')"
			cat >Release <<EOF
Origin: Hayato
Label: Hayato
Suite: $DEFAULT_SUITE
Codename: $DEFAULT_SUITE
Date: $(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S UTC')
Architectures: arm64 amd64
Components: main
Description: Hayato Debian repository
MD5Sum:
 $p_md5 $p_size Packages
 $p_gz_md5 $p_gz_size Packages.gz
SHA256:
 $p_sha $p_size Packages
 $p_gz_sha $p_gz_size Packages.gz
EOF
		fi

		local sign_homedir="" cleanup_gpg="no"
		if [ -n "${HAYATO_APT_GPG_PRIVATE_KEY:-}" ]; then
			sign_homedir="$(mktemp -d /tmp/hayato-sign.XXXXXX)"
			chmod 700 "$sign_homedir"
			cleanup_gpg="yes"
			printf '%s\n' "$HAYATO_APT_GPG_PRIVATE_KEY" |
				GNUPGHOME="$sign_homedir" gpg --batch --yes --import >/dev/null 2>&1
		elif [ -n "${GNUPGHOME:-}" ] && gpg --batch --list-secret-keys >/dev/null 2>&1; then
			sign_homedir="$GNUPGHOME"
		fi

		if [ -n "$sign_homedir" ] && GNUPGHOME="$sign_homedir" gpg --batch --list-secret-keys | grep -q 'sec'; then
			GNUPGHOME="$sign_homedir" gpg --batch --yes --digest-algo SHA256 --clearsign -o InRelease Release 2>/dev/null ||
				GNUPGHOME="$sign_homedir" gpg --batch --yes --clearsign -o InRelease Release
			GNUPGHOME="$sign_homedir" gpg --batch --yes -abs -o Release.gpg Release
			log "Signed APT metadata (InRelease, Release.gpg)"
		fi
		[ "$cleanup_gpg" = "yes" ] && rm -rf "$sign_homedir" || true
	)
	log "Built APT repository index in $dir"
}

cmd_upgrade_from_github() {
	local repo="$DEFAULT_GITHUB_REPO"
	local tag="latest"
	local dir=""
	local dry_run="no"
	local orig_args=("upgrade-from-github" "$@")

	while [ "$#" -gt 0 ]; do
		case "$1" in
			--repo) repo="${2:-}"; shift 2 ;;
			--tag) tag="${2:-}"; shift 2 ;;
			--dir) dir="${2:-}"; shift 2 ;;
			--dry-run) dry_run="yes"; shift ;;
			*) die "unknown option for upgrade-from-github: $1" ;;
		esac
	done

	if [ "$dry_run" != "yes" ]; then
		need_root_reexec "${orig_args[@]}"
	fi

	local dev="google-asurada"
	if [ -f /etc/hayato/device ]; then
		dev="$(tr -d ' \t\r\n' </etc/hayato/device)"
	fi

	local tmp_dir=""
	if [ -z "$dir" ]; then
		tmp_dir="$(mktemp -d /var/tmp/hayato-gh-upgrade.XXXXXX)"
		trap 'rm -rf "$tmp_dir"' EXIT
		dir="$tmp_dir"
		log "Fetching release assets from GitHub ($repo, tag=$tag) for device $dev"
		if command -v gh >/dev/null 2>&1; then
			local gh_tag=()
			[ "$tag" != "latest" ] && gh_tag=("$tag")
			gh release download "${gh_tag[@]}" --repo "$repo" --dir "$dir" \
				--pattern "SHA256SUMS" --pattern "InRelease" --pattern "Release*" \
				--pattern "*.deb"
		else
			die "gh CLI is required to download release assets (or pass --dir <LOCAL_DIR>)"
		fi
	fi

	[ -d "$dir" ] || die "directory not found: $dir"
	if [ -f "$dir/SHA256SUMS" ]; then
		(
			cd "$dir"
			sha256sum -c --ignore-missing SHA256SUMS
		) || die "SHA256SUMS verification failed in $dir"
	fi

	local -a debs=()
	for f in "$dir"/*.deb; do
		[ -f "$f" ] || continue
		local base
		base="$(basename "$f")"
		case "$base" in
			hayato-device-*)
				case "$base" in
					"hayato-device-${dev}_"*) debs+=("$f") ;;
				esac
				;;
			*)
				debs+=("$f")
				;;
		esac
	done

	[ "${#debs[@]}" -gt 0 ] || die "no matching .deb packages found in $dir"
	log "Matched ${#debs[@]} package(s) for $dev:"
	printf '  %s\n' "${debs[@]}"

	if [ "$dry_run" = "yes" ]; then
		log "Dry run complete (no packages installed)"
		return 0
	fi

	DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
		-o Dpkg::Options::=--force-confdef \
		-o Dpkg::Options::=--force-confnew \
		"${debs[@]}"
	log "Upgrade from GitHub release packages complete"
}

sub="${1:-status}"
[ "$#" -gt 0 ] && shift

case "$sub" in
	-h|--help|help) usage ;;
	status) cmd_status "$@" ;;
	enable) cmd_enable "$@" ;;
	disable) cmd_disable "$@" ;;
	build-repo) cmd_build_repo "$@" ;;
	upgrade-from-github) cmd_upgrade_from_github "$@" ;;
	*) die "unknown subcommand '$sub' (try: hayato-apt --help)" ;;
esac
