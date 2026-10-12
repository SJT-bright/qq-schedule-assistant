#!/bin/bash
# Keep the local signing identity across builds so TCC can recognize updates.
set -euo pipefail
APP="${1:?Usage: sign-app.sh path/to/app}"
IDENTITY="${QQ_DISPATCH_SIGNING_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  SIGNING_DIR="$HOME/Library/Application Support/QQDispatchSigning"
  mkdir -p "$SIGNING_DIR"
  chmod 700 "$SIGNING_DIR"
  if [[ ! -f "$SIGNING_DIR/identity.sha1" ]]; then
    bash "$(dirname "$0")/create-signing-identity.sh"
  fi
  IDENTITY=$(cat "$SIGNING_DIR/identity.sha1")
  # Pin the certificate, not only the bundle identifier. Never fall back to ad hoc.
  codesign --force --sign "$IDENTITY" --timestamp=none \
    --requirements "=designated => identifier \"local.felix.qqdispatch\" and certificate leaf = H\"$IDENTITY\"" "$APP"
else
  codesign --force --sign "$IDENTITY" "$APP"
fi
codesign --verify --strict "$APP"
