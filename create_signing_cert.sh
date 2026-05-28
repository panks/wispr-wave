#!/bin/bash
#
# Sets up the WisprWave code-signing identity in your login keychain.
#
# Modes:
#   ./create_signing_cert.sh                  Generate a new self-signed identity.
#   ./create_signing_cert.sh <path-to-.p12>   Restore from a previously-exported .p12
#                                             (use export_signing_cert.sh to make one).
#
# Why this matters: WisprWave ships without an Apple Developer ID. Ad-hoc signing
# (`codesign -s -`) gives the app an identity equal to its content hash (cdhash), which
# changes on every rebuild — and macOS ties the Accessibility (TCC) grant to that
# identity, so the permission breaks after each update.
#
# A stable code-signing cert gives the app a constant "designated requirement" (tied to
# the cert, not the binary). Reusing the same cert across rebuilds — and across machines
# via .p12 export/import — lets the Accessibility grant persist for you and any users
# who installed an earlier signed build.
#
# Run this once on each machine you build from. package_app.sh picks the identity up
# automatically. To undo: delete the "WisprWave Local Signing" cert in Keychain Access.

set -e

CERT_NAME="WisprWave Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
P12_INPUT="${1:-}"

# `-v` only lists trusted identities; a self-signed cert is not trusted by policy, so
# the unfiltered listing is what we need to detect existence.
if security find-identity -p codesigning "$KEYCHAIN" | grep -q "$CERT_NAME"; then
    echo "✅ Identity '$CERT_NAME' already exists in your login keychain. Nothing to do."
    echo "   To replace it, delete it first in Keychain Access (login keychain)."
    exit 0
fi

# Mode 1: restore from an existing .p12 (preserves the original Designated Requirement).
if [ -n "$P12_INPUT" ]; then
    if [ ! -r "$P12_INPUT" ]; then
        echo "❌ Cannot read '$P12_INPUT'."
        exit 1
    fi
    echo "📥 Restoring signing identity from $P12_INPUT ..."
    read -r -s -p "Passphrase for $P12_INPUT: " PASS; echo
    # -A allows all apps (incl. codesign) to use the key without an extra auth prompt.
    security import "$P12_INPUT" -k "$KEYCHAIN" -P "$PASS" -A
    echo ""
    echo "✅ Imported identity '$CERT_NAME' from $P12_INPUT."
    echo "   You can now run ./package_app.sh — it will sign with this identity automatically."
    exit 0
fi

# Mode 2: generate a fresh self-signed identity.
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

security import "$TMP/cert.p12" -k "$KEYCHAIN" -P "$P12_PASS" -A

echo ""
echo "✅ Created code-signing identity '$CERT_NAME'."
echo "   You can now run ./package_app.sh — it will sign with this identity automatically."
echo "   Back this identity up to a portable .p12:  ./export_signing_cert.sh"
