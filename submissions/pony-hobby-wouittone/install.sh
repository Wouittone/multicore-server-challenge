#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends ca-certificates curl git build-essential libssl-dev libcrypt-dev

install_release() {
  local repo="$1" version="$2" archive="$3" dest="$4"
  local tmp
  tmp="$(mktemp -d)"
  (
    trap 'rm -rf "$tmp"' EXIT
    cd "$tmp"
    local url="https://github.com/ponylang/$repo/releases/download/$version/$archive"
    curl --fail --location --retry 3 -o "$archive" "$url"
    curl --fail --location --retry 3 -o "$archive.sha512" "$url.sha512"
    printf '%s  %s\n' "$(cat "$archive.sha512")" "$archive" | sha512sum --check -
    mkdir -p "$dest"
    tar -xzf "$archive" -C "$dest" --strip-components=1
  )
}

install_release ponyc 0.77.2 ponyc-x86-64-unknown-linux-ubuntu24.04.tar.gz /opt/conduit-ponyc-0.77.2
install_release corral 0.9.2 corral-x86-64-unknown-linux.tar.gz /opt/conduit-corral-0.9.2
