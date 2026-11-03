#!/bin/bash
# Signs a release's checksum list with minisign: SHA256SUMS-<version>.minisig, uploaded beside it. The checksum
# list covers the AppImage, its .zsync and the tar.gz, so one signature covers them all.
#   tools/release/sign.sh <dir with SHA256SUMS-<version>> <version>
# MINISIGN_KEY: the secret key (default ~/.minisign/yorishiro.key). minisign asks for its password.
# Checking a download (the public key is in the README):
#   minisign -Vm SHA256SUMS-<version> -P <public key> && sha256sum -c --ignore-missing SHA256SUMS-<version>
set -euo pipefail
DIR=${1:?usage: sign.sh <dir> <version>}
VERSION=${2:?usage: sign.sh <dir> <version>}
KEY=${MINISIGN_KEY:-$HOME/.minisign/yorishiro.key}
sums=$DIR/SHA256SUMS-$VERSION
command -v minisign > /dev/null || { echo "minisign is not installed"; exit 1; }
[ -f "$sums" ] || { echo "no $sums"; exit 1; }
[ -f "$KEY" ] || { echo "no secret key at $KEY"; exit 1; }
(cd "$DIR" && sha256sum -c --quiet "SHA256SUMS-$VERSION") || { echo "the files do not match $sums"; exit 1; }
minisign -S -s "$KEY" -m "$sums" -t "Yorishiro $VERSION"
echo "signed: $sums.minisig"
