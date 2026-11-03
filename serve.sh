#!/usr/bin/env bash
# Serve the built game on http://localhost:8081
set -euo pipefail
cd "$(dirname "$0")/build-web"
if [[ ! -e Data.rsdk ]]; then
    echo "error: build-web/Data.rsdk is missing."
    echo "       ln -s /path/to/your/Data.rsdk build-web/Data.rsdk"
    exit 1
fi
echo "Sonic Mania (wasm) -> http://localhost:8081/index.html"
exec python3 -m http.server 8081
