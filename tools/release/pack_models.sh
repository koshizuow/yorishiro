#!/bin/bash
# Packs the tracking models for the models-<n> release that CI downloads (.github/workflows/release.yml):
# exactly the files models/SHA256SUMS lists, at their paths, so CI can check them with it.
#   MODELS_DIR=<models> tools/release/pack_models.sh <name>      (e.g. models-v1 -> models-v1.tar.gz)
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
NAME=${1:?usage: pack_models.sh <name>}
MODELS=$(realpath "${MODELS_DIR:-$ROOT/models}")
(cd "$MODELS" && sha256sum -c --quiet "$ROOT/models/SHA256SUMS") || { echo "the models do not match models/SHA256SUMS"; exit 1; }
tar czf "$NAME.tar.gz" -C "$MODELS" $(awk '{print $2}' "$ROOT/models/SHA256SUMS")
sha256sum "$NAME.tar.gz"
