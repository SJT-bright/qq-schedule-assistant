#!/bin/bash
# Run after the installed app has been reopened; validation precedes cleanup.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 Tools/cleanup-old-versions.py --after-update
