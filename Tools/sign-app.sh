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
    umask 077
    TEMP_DIR=$(mktemp -d)
    trap 'rm -rf "$TEMP_DIR"' EXIT
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
      -subj '/CN=QQDispatch Local Code Signing/' \
      -addext 'keyUsage=critical,digitalSignature' \
      -addext 'extendedKeyUsage=critical,codeSigning' \
      -keyout "$TEMP_DIR/key.pem" -out "$TEMP_DIR/cert.pem" 2>/dev/null
    export QQ_SIGNING_IMPORT_PASSWORD=$(openssl rand -hex 24)
    openssl pkcs12 -export -legacy -macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -inkey "$TEMP_DIR/key.pem" \
      -in "$TEMP_DIR/cert.pem" -out "$TEMP_DIR/identity.p12" -passout env:QQ_SIGNING_IMPORT_PASSWORD
    security import "$TEMP_DIR/identity.p12" \
      -k "$HOME/Library/Keychains/login.keychain-db" -P "$QQ_SIGNING_IMPORT_PASSWORD" -T /usr/bin/codesign
    unset QQ_SIGNING_IMPORT_PASSWORD
    openssl x509 -in "$TEMP_DIR/cert.pem" -noout -fingerprint -sha1 \
      | cut -d= -f2 | tr -d ':' > "$SIGNING_DIR/identity.sha1"
  fi
  IDENTITY=$(cat "$SIGNING_DIR/identity.sha1")
  # Pin the certificate, not only the bundle identifier. Never fall back to ad hoc.
  codesign --force --sign "$IDENTITY" --timestamp=none \
    --requirements "=designated => identifier \"local.felix.qqdispatch\" and certificate leaf = H\"$IDENTITY\"" "$APP"
else
  codesign --force --sign "$IDENTITY" "$APP"
fi
codesign --verify --strict "$APP"
