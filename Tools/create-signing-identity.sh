#!/bin/bash
# Create a reusable local signing identity. --rotate explicitly replaces the pin.
set -euo pipefail
umask 077

MODE="${1:-}"
if [[ -n "$MODE" && "$MODE" != "--rotate" ]]; then
  echo "Usage: create-signing-identity.sh [--rotate]" >&2
  exit 2
fi

SIGNING_DIR="$HOME/Library/Application Support/QQDispatchSigning"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
PIN="$SIGNING_DIR/identity.sha1"
mkdir -p "$SIGNING_DIR"
chmod 700 "$SIGNING_DIR"
if [[ -f "$PIN" && "$MODE" != "--rotate" ]]; then
  echo "Signing identity pin already exists; use --rotate for an intentional change." >&2
  exit 1
fi

TEMP_DIR=$(mktemp -d "$SIGNING_DIR/.new-identity.XXXXXX")
trap 'rm -rf "$TEMP_DIR"' EXIT
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -subj '/CN=QQDispatch Local Code Signing/' \
  -addext 'keyUsage=critical,digitalSignature' \
  -addext 'extendedKeyUsage=critical,codeSigning' \
  -keyout "$TEMP_DIR/key.pem" -out "$TEMP_DIR/cert.pem" 2>/dev/null
openssl rand -hex 32 > "$TEMP_DIR/recovery.pass"
openssl pkcs12 -export -legacy -macalg sha1 \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES \
  -inkey "$TEMP_DIR/key.pem" -in "$TEMP_DIR/cert.pem" \
  -out "$TEMP_DIR/identity.p12" -passout "file:$TEMP_DIR/recovery.pass"

NEW_SHA=$(openssl x509 -in "$TEMP_DIR/cert.pem" -noout -fingerprint -sha1 \
  | cut -d= -f2 | tr -d ':' | tr '[:lower:]' '[:upper:]')
if [[ ! "$NEW_SHA" =~ ^[0-9A-F]{40}$ ]]; then
  echo "Could not derive the new certificate fingerprint." >&2
  exit 1
fi
# Keep a recoverable encrypted export even if import or trust setup fails.
P12="$SIGNING_DIR/identity-$NEW_SHA.p12"
PASS="$SIGNING_DIR/identity-$NEW_SHA.pass"
CERT="$SIGNING_DIR/identity-$NEW_SHA.cert.pem"
if [[ -e "$P12" || -e "$PASS" || -e "$CERT" ]]; then
  echo "Recovery archive already exists for the new identity." >&2
  exit 1
fi
mv "$TEMP_DIR/identity.p12" "$P12"
mv "$TEMP_DIR/recovery.pass" "$PASS"
mv "$TEMP_DIR/cert.pem" "$CERT"
chmod 600 "$P12" "$PASS" "$CERT"
security import "$P12" -k "$KEYCHAIN" \
  -P "$(cat "$PASS")" -T /usr/bin/codesign
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$CERT"
if ! security find-identity -v -p codesigning "$KEYCHAIN" | grep -Fq "$NEW_SHA"; then
  echo "New signing identity is not usable; recovery files remain at $P12." >&2
  exit 1
fi
if [[ -f "$PIN" ]]; then
  OLD_SHA=$(tr -d '[:space:]' < "$PIN" | tr '[:lower:]' '[:upper:]')
  cp -p "$PIN" "$SIGNING_DIR/identity-before-$NEW_SHA.sha1"
  echo "Previous signing fingerprint preserved: $OLD_SHA"
fi
printf '%s\n' "$NEW_SHA" > "$TEMP_DIR/identity.sha1"
mv "$TEMP_DIR/identity.sha1" "$PIN"
chmod 600 "$PIN"
echo "Active signing fingerprint: $NEW_SHA"
echo "Encrypted recovery archive: $P12"
