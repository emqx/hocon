#!/bin/bash

set -euo pipefail

ELVIS_VERSION='3.2.6-emqx-1'
ELVIS_SHA256='a9b92b72bc031cce3c6b743418e404a763303ca9f2bf3141eb8af8f22c4176fa'

elvis_version="${2:-$ELVIS_VERSION}"

echo "elvis -v: $elvis_version"

if [ "$elvis_version" = "$ELVIS_VERSION" ]; then
    elvis_sha256="$ELVIS_SHA256"
else
    elvis_sha256=''
fi

if [ ! -f ./elvis ] || [ "$(sha256sum ./elvis | cut -d ' ' -f 1)" != "$elvis_sha256" ]; then
    curl  -fLO "https://github.com/emqx/elvis/releases/download/$elvis_version/elvis"
    if [ -n "$elvis_sha256" ] && [ "$(sha256sum ./elvis | cut -d ' ' -f 1)" != "$elvis_sha256" ]; then
        echo "elvis checksum mismatch" >&2
        exit 1
    fi
    chmod +x ./elvis
fi

./elvis rock --config elvis.config
