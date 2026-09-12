#!/bin/bash
set -euo pipefail

HELPER_DIR="$(cd "$(dirname "$0")" && pwd)"
PYTHON_BIN="$HELPER_DIR/../venv313/bin/python"

cd "$HELPER_DIR"
export PYTHONDONTWRITEBYTECODE=1
exec "$PYTHON_BIN" -m unittest discover -s tests -v
