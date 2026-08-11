#!/bin/bash
set -euo pipefail

HELPER_DIR="$(cd "$(dirname "$0")" && pwd)"
PYTHON_BIN="$HELPER_DIR/../venv313/bin/python"

if [[ ! -x "$PYTHON_BIN" ]]; then
  echo "Python 3.13 helper environment not found: $PYTHON_BIN" >&2
  exit 2
fi

cd "$HELPER_DIR"
export PYTHONDONTWRITEBYTECODE=1
exec "$PYTHON_BIN" -m performance_helper "$@"
