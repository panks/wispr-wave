#!/bin/bash
#
# Creates a stable, self-signed code-signing certificate in your login keychain.
#
# Why: WisprWave is distributed without an Apple Developer ID. If we sign ad-hoc
# (`codesign -s -`), the app's identity is its content hash (cdhash), which changes
# on every rebuild. macOS ties the Accessibility (TCC) grant to that identity, so the
# permission stops working after each update and must be re-granted.
#
# A self-signed certificate gives the app a *stable* "designated requirement" (tied to
# the certificate, not the binary contents). Reusing the same cert across rebuilds lets
# the Accessibility grant persist. This is a LOCAL cert only — it does not bypass
# Gatekeeper (you'll still "Open Anyway" on first launch) and is not for distribution.
#
# Run this once. package_app.sh will automatically pick the identity up.
# To undo: delete the "WisprWave Local Signing" cert in Keychain Access (login keychain).

set -e

CERT_NAME="WisprWave Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "$CERT_NAME"; then
    echo "✅ Code-signing identity '$CERT_NAME' already exists. Nothing to do."
    exit 0
fi

# Prefer Homebrew OpenSSL (supports the config below reliably); fall back to system.
OPENSSL="$(command -v openssl)"

echo "🔐 Generating self-signed code-signing certificate '$CERT_NAME'..."

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
[dn]
CN = $CERT_NAME
[v3]
basicConstraints     = critical,CA:false
keyUsage             = critical,digitalSignature
extendedKeyUsage     = critical,codeSigning
EOF

"$OPENSSL" req -x509 -newkey rsa:2048 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 \
    -config "$TMP/cert.cnf" >/dev/null 2>&1

# OpenSSL 3.x defaults to a PKCS#12 MAC that macOS's `security import` can't verify.
# Use -legacy (when available) and a passphrase so the import succeeds.
P12_PASS="wisprwave"
LEGACY_FLAG=""
if "$OPENSSL" pkcs12 -help 2>&1 | grep -q -- "-legacy"; then
    LEGACY_FLAG="-legacy"
fi

"$OPENSSL" pkcs12 -export $LEGACY_FLAG -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/cert.p12" -passout "pass:$P12_PASS" -name "$CERT_NAME" >/dev/null 2>&1

# Import into the login keychain. -A allows all apps (incl. codesign) to use the key
# without an additional authorization prompt.
security import "$TMP/cert.p12" -k "$KEYCHAIN" -P "$P12_PASS" -A

echo ""
echo "✅ Created code-signing identity '$CERT_NAME'."
echo "   You can now run ./package_app.sh — it will sign with this identity automatically."
