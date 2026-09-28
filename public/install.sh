#!/bin/sh
# SyncMyEnv installer — https://syncmyenv.com/install.sh
#
#   curl -fsSL https://syncmyenv.com/install.sh | sh
#
# Good instinct to read this first. It will:
#   1. detect your OS and CPU
#   2. download `sme` from GitHub Releases (github.com/syncmyenv/core)
#   3. verify the SHA-256 checksum — and the Sigstore signature if `cosign` is installed
#   4. install it to ~/.local/bin (no sudo), plus a `syncmyenv` alias
# Nothing else: no telemetry, no shell rc edits, no sudo.
#
# Options (environment variables):
#   SME_VERSION=v0.1.0          install a specific version (default: latest)
#   SME_INSTALL_DIR=/usr/local/bin   install somewhere else
#
# Prefer a package manager?   brew install syncmyenv/tap/sme
# Or build from source:        go install github.com/syncmyenv/core/cmd/syncmyenv@latest

set -eu

REPO="syncmyenv/core"
VERSION="${SME_VERSION:-latest}"
INSTALL_DIR="${SME_INSTALL_DIR:-$HOME/.local/bin}"
BASE="${SME_DOWNLOAD_BASE:-https://github.com/$REPO/releases/download}"
IDENTITY="^https://github.com/$REPO/\.github/workflows/release\.yml@refs/tags/v"
ISSUER="https://token.actions.githubusercontent.com"

G='' R='' N=''
if [ -t 1 ]; then G=$(printf '\033[32m') R=$(printf '\033[31m') N=$(printf '\033[0m'); fi
say() { printf '%s\n' "$*"; }
ok()  { printf '%s✓%s %s\n' "$G" "$N" "$*"; }
die() { printf '%s✗%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
has() { command -v "$1" >/dev/null 2>&1; }

fetch() { # url dest
	if has curl; then curl -fsL --proto '=https,http' --retry 2 -o "$2" "$1"
	elif has wget; then wget -q -O "$2" "$1"
	else die "need curl or wget"; fi
}

sha256() {
	if has sha256sum; then sha256sum "$1" | cut -d' ' -f1
	elif has shasum; then shasum -a 256 "$1" | cut -d' ' -f1
	elif has openssl; then openssl dgst -sha256 "$1" | sed 's/.*= //'
	else die "need sha256sum, shasum or openssl to verify the download"; fi
}

detect_platform() {
	case "$(uname -s)" in
		Darwin) OS=darwin ;;
		Linux) OS=linux ;;
		MINGW* | MSYS* | CYGWIN*) die "on Windows, download the .zip from https://github.com/$REPO/releases or use: go install github.com/syncmyenv/core/cmd/syncmyenv@latest" ;;
		*) die "unsupported OS: $(uname -s)" ;;
	esac
	case "$(uname -m)" in
		x86_64 | amd64) ARCH=amd64 ;;
		arm64 | aarch64) ARCH=arm64 ;;
		*) die "unsupported CPU: $(uname -m)" ;;
	esac
}

resolve_version() {
	[ "$VERSION" != latest ] && return
	# 1st: the /releases/latest redirect (no API rate limit); 2nd: the API
	# (for proxies that block github.com pages but not the API, and for wget).
	VERSION=""
	if has curl; then
		url=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest" 2>/dev/null || true)
		VERSION=${url##*/}
	fi
	case "$VERSION" in
		v[0-9]*) ;;
		*)
			api="https://api.github.com/repos/$REPO/releases/latest"
			if has curl; then json=$(curl -fsSL "$api" 2>/dev/null || true); else json=$(wget -qO- "$api" 2>/dev/null || true); fi
			VERSION=$(printf '%s' "$json" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n1)
			;;
	esac
	case "$VERSION" in
		v[0-9]*) ;;
		*) die "no release published yet — for now: go install github.com/syncmyenv/core/cmd/syncmyenv@latest" ;;
	esac
}

main() {
	detect_platform
	resolve_version
	num=${VERSION#v}
	archive="sme_${num}_${OS}_${ARCH}.tar.gz"
	url="$BASE/$VERSION"

	tmp=$(mktemp -d 2>/dev/null || mktemp -d -t sme)
	trap 'rm -rf "$tmp"' EXIT INT TERM

	say "→ sme $VERSION for $OS/$ARCH"
	fetch "$url/checksums.txt" "$tmp/checksums.txt" || die "couldn't download checksums for $VERSION (does that release exist?)"
	fetch "$url/$archive" "$tmp/$archive" || die "couldn't download $archive"

	# 1. signature over checksums.txt (if cosign is available)
	if has cosign; then
		fetch "$url/checksums.txt.pem" "$tmp/checksums.txt.pem" || die "release is missing its signing certificate"
		fetch "$url/checksums.txt.sig" "$tmp/checksums.txt.sig" || die "release is missing its signature"
		cosign verify-blob "$tmp/checksums.txt" \
			--certificate "$tmp/checksums.txt.pem" --signature "$tmp/checksums.txt.sig" \
			--certificate-identity-regexp "$IDENTITY" --certificate-oidc-issuer "$ISSUER" >/dev/null 2>&1 ||
			die "SIGNATURE VERIFICATION FAILED — not installing. Please report: https://github.com/$REPO/security"
		ok "signature verified (sigstore, built by github.com/$REPO)"
	fi

	# 2. archive against checksums.txt
	want=$(awk -v f="$archive" '$2 == f { print $1 }' "$tmp/checksums.txt")
	[ -n "$want" ] || die "$archive isn't listed in checksums.txt"
	got=$(sha256 "$tmp/$archive")
	[ "$want" = "$got" ] || die "CHECKSUM MISMATCH for $archive — not installing (expected $want, got $got)"
	ok "checksum verified"

	tar -xzf "$tmp/$archive" -C "$tmp" sme
	mkdir -p "$INSTALL_DIR" 2>/dev/null || true
	[ -w "$INSTALL_DIR" ] || die "$INSTALL_DIR isn't writable — try: SME_INSTALL_DIR=\$HOME/.local/bin (or run with sudo if you really want a system dir)"

	prev=""
	[ -x "$INSTALL_DIR/sme" ] && prev=$("$INSTALL_DIR/sme" --version 2>/dev/null | awk '{print $3}') || true
	cp "$tmp/sme" "$INSTALL_DIR/sme.new"
	chmod 0755 "$INSTALL_DIR/sme.new"
	mv -f "$INSTALL_DIR/sme.new" "$INSTALL_DIR/sme" # atomic replace (safe while the daemon runs)
	ln -sf sme "$INSTALL_DIR/syncmyenv"

	if [ -n "$prev" ]; then ok "upgraded sme $prev → $num in $INSTALL_DIR"; else ok "installed sme $num to $INSTALL_DIR"; fi
	has cosign || say "  tip: install cosign to also verify the release signature next time"

	case ":$PATH:" in
		*":$INSTALL_DIR:"*) ;;
		*)
			say ""
			say "  $INSTALL_DIR isn't on your PATH. Add it:"
			say "    echo 'export PATH=\"$INSTALL_DIR:\$PATH\"' >> ~/.$(basename "${SHELL:-sh}")rc"
			;;
	esac
	if [ -n "$prev" ]; then
		say "  if the daemon is running, restart it on the new version: sme daemon install"
	fi

	say ""
	say "  next:  sme init && sme protect ~/Projects && sme daemon install"
}

main "$@" # everything above only defines functions: a truncated download can't run half a script
