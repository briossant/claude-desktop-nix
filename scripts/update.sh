#!/usr/bin/env bash
#
# Update flake.nix to the latest claude-desktop version published in
# Anthropic's apt repository — but only after authenticating the metadata:
#
#   1. the repo signing key is pinned by fingerprint (published at
#      https://code.claude.com/docs/en/desktop-linux);
#   2. the InRelease file must carry a valid signature from that key;
#   3. each Packages index must match the SHA256 listed in InRelease;
#   4. the per-arch deb SHA256 is then copied from the verified Packages.
#
# So the hashes that land in flake.nix are Anthropic's own, end to end.
set -euo pipefail

EXPECTED_FPR="31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE"
REPO="https://downloads.claude.ai/claude-desktop"
FLAKE_FILE="$(dirname "$0")/../flake.nix"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export GNUPGHOME="$tmp/gnupg"
mkdir -p -m 700 "$GNUPGHOME"

# --- 1. pin the signing key by fingerprint --------------------------------
curl -fsSL "$REPO/key.asc" -o "$tmp/key.asc"
fpr="$(gpg --batch --show-keys --with-colons "$tmp/key.asc" | awk -F: '/^fpr:/ { print $10; exit }')"
if [[ "$fpr" != "$EXPECTED_FPR" ]]; then
  echo "Signing key fingerprint mismatch: got $fpr, expected $EXPECTED_FPR" >&2
  exit 1
fi
gpg --batch --quiet --import "$tmp/key.asc"

# --- 2. verify the signed InRelease (also strips the signature) -----------
curl -fsSL "$REPO/apt/stable/dists/stable/InRelease" -o "$tmp/InRelease"
if ! gpg --batch --quiet --output "$tmp/Release" --decrypt "$tmp/InRelease" 2> "$tmp/gpg.log"; then
  echo "InRelease signature verification FAILED:" >&2
  cat "$tmp/gpg.log" >&2
  exit 1
fi

# --- 3. fetch each Packages index and check it against InRelease ----------
fetch_packages() {
  local deb_arch="$1"
  curl -fsSL "$REPO/apt/stable/dists/stable/main/binary-$deb_arch/Packages" > "$tmp/Packages.$deb_arch"
  local want got
  want="$(awk -v f="main/binary-$deb_arch/Packages" '
    /^SHA256:/ { s = 1; next }
    /^[A-Za-z]/ { s = 0 }
    s && $3 == f { print $1; exit }
  ' "$tmp/Release")"
  got="$(sha256sum "$tmp/Packages.$deb_arch" | cut -d' ' -f1)"
  if [[ -z "$want" || "$want" != "$got" ]]; then
    echo "Packages index for $deb_arch does not match signed InRelease (want=$want got=$got)" >&2
    exit 1
  fi
}

# --- 4. latest claude-desktop entry per arch ------------------------------
latest_field() {
  local deb_arch="$1" field="$2"
  awk -v field="$field" '
    BEGIN { RS = ""; FS = "\n" }
    {
      package = ""; version = ""; value = ""
      for (i = 1; i <= NF; i++) {
        if ($i == "Package: claude-desktop") package = "claude-desktop"
        if ($i ~ "^Version: ") version = substr($i, 10)
        if ($i ~ "^" field ": ") value = substr($i, length(field) + 3)
      }
      if (package == "claude-desktop" && version != "" && value != "") print version "\t" value
    }
  ' "$tmp/Packages.$deb_arch" | sort -V | tail -n1 | cut -f2-
}

require_latest_field() {
  local value
  value="$(latest_field "$1" "$2")"
  if [[ -z "$value" ]]; then
    echo "Could not find $2 for claude-desktop in $1 Packages metadata" >&2
    exit 1
  fi
  printf '%s\n' "$value"
}

to_sri() {
  nix hash convert --hash-algo sha256 --to sri "$1"
}

fetch_packages amd64
fetch_packages arm64

version_amd64="$(require_latest_field amd64 Version)"
version_arm64="$(require_latest_field arm64 Version)"
if [[ "$version_amd64" != "$version_arm64" ]]; then
  echo "Version mismatch: amd64=$version_amd64 arm64=$version_arm64" >&2
  exit 1
fi

hash_amd64="$(to_sri "$(require_latest_field amd64 SHA256)")"
hash_arm64="$(to_sri "$(require_latest_field arm64 SHA256)")"

# --- 5. patch flake.nix (targets the marker comments) ----------------------
VERSION="$version_amd64" HASH_AMD64="$hash_amd64" HASH_ARM64="$hash_arm64" perl -0pi -e '
  s{version = "[^"]+"; # claude-desktop-version}{version = "$ENV{VERSION}"; # claude-desktop-version} or die "version marker not found\n";
  s{hash = "[^"]+"; # deb-hash-amd64}{hash = "$ENV{HASH_AMD64}"; # deb-hash-amd64} or die "amd64 hash marker not found\n";
  s{hash = "[^"]+"; # deb-hash-arm64}{hash = "$ENV{HASH_ARM64}"; # deb-hash-arm64} or die "arm64 hash marker not found\n";
' "$FLAKE_FILE"

echo "flake.nix is at claude-desktop $version_amd64 (GPG-verified metadata)"
