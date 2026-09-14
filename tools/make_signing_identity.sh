#!/bin/zsh
# Creates a local self-signed code-signing identity "FXMic Dev" in its own keychain, usable by codesign without prompts.
# Signing every build with the same identity keeps macOS permission grants (Accessibility, Microphone) across rebuilds.
set -euo pipefail
NAME="FXMic Dev"
KC="$HOME/Library/Keychains/fxmic-signing.keychain-db"
PWFILE="$HOME/.fxmic/signing-keychain.pw"
mkdir -p "$HOME/.fxmic"
if security find-identity -v -p codesigning "$KC" 2>/dev/null | grep -q "$NAME"; then echo "identity '$NAME' already exists in $KC"; exit 0; fi
[ -f "$PWFILE" ] || { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32 > "$PWFILE"; chmod 600 "$PWFILE"; }
PW="$(cat "$PWFILE")"
TMP="$(mktemp -d)"
cat > "$TMP/ext.cnf" <<CNF
[req]
distinguished_name = dn
prompt = no
[dn]
CN = $NAME
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
subjectKeyIdentifier = hash
CNF
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/ext.cnf" -extensions ext >/dev/null 2>&1
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" -out "$TMP/id.p12" -passout "pass:$PW" -legacy 2>/dev/null || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" -out "$TMP/id.p12" -passout "pass:$PW"
[ -f "$KC" ] || security create-keychain -p "$PW" "$KC"
security set-keychain-settings "$KC"                       # no auto-lock
security unlock-keychain -p "$PW" "$KC"
security import "$TMP/id.p12" -k "$KC" -P "$PW" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PW" "$KC" >/dev/null
# add to the search list (keep the existing ones)
EXISTING=$(security list-keychains -d user | tr -d '" ' )
security list-keychains -d user -s $EXISTING "$KC"
# trust the certificate for code signing so codesign accepts it without a UI prompt
security add-trusted-cert -d -r trustRoot -p codeSign -k "$KC" "$TMP/cert.pem" 2>/dev/null || security add-trusted-cert -r trustRoot -p codeSign -k "$KC" "$TMP/cert.pem" 2>/dev/null || echo "(could not mark the certificate trusted automatically; codesign may still accept it)"
rm -rf "$TMP"
security find-identity -v -p codesigning "$KC" | grep "$NAME" || { echo "identity not found after import"; exit 1; }
echo "created identity '$NAME' in $KC"
