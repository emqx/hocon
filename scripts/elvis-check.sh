#!/bin/bash

set -euo pipefail

ELVIS_VERSION='3.2.6-emqx-1'
ELVIS_CACHE_FILE='.elvis.lock'

elvis_version="${2:-$ELVIS_VERSION}"

echo "elvis -v: $elvis_version"

cached_version=''
cached_sha256=''
if [ -f "$ELVIS_CACHE_FILE" ]; then
    read -r cached_version cached_sha256 < "$ELVIS_CACHE_FILE" || true
fi

actual_sha256=''
if [ -f ./elvis ]; then
    actual_sha256="$(sha256sum ./elvis | cut -d ' ' -f 1)"
fi

if [ ! -f ./elvis ] || [ "$cached_version" != "$elvis_version" ] || [ "$cached_sha256" != "$actual_sha256" ]; then
    curl  -fLO "https://github.com/emqx/elvis/releases/download/$elvis_version/elvis"
    actual_sha256="$(sha256sum ./elvis | cut -d ' ' -f 1)"
    chmod +x ./elvis
    printf '%s %s\n' "$elvis_version" "$actual_sha256" > "$ELVIS_CACHE_FILE"
fi

./elvis rock --config elvis.config
