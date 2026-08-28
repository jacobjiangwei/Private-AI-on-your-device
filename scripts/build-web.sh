#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/WebBuild"
OUTPUT="$ROOT/PrivateAI/PrivateAI/Web"

if ! command -v npm >/dev/null 2>&1; then
    [[ -f "$OUTPUT/vendor.js" ]] && exit 0
    echo "npm is required because the committed Web bundle is missing." >&2
    exit 1
fi

npm --prefix "$SOURCE" ci --no-audit --no-fund
npm --prefix "$SOURCE" run build
