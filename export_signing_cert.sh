#!/bin/bash
#
# Exports the "WisprWave Local Signing" code-signing identity (cert + private key)
# from your login keychain into a portable PKCS#12 file.
#
# Usage:
#   ./export_signing_cert.sh [output.p12]
#
# Default output: WisprWave-signing.p12 in the current directory.
# You'll be prompted for a passphrase to protect the .p12.
#
# Back this file up securely (password manager, encrypted backup, etc.) so a future
# machine can keep producing builds with the same Designated Requirement — that's
# what lets your existing users' Accessibility grants survive across updates.
#
# ⚠️  DO NOT COMMIT THIS .p12 TO A PUBLIC REPO. It contains your private signing key;
# anyone with it can sign binaries as your identity and inherit any TCC grants that
# trust it. The default filename is in .gitignore as a guardrail.
#
# To restore on another Mac:  ./create_signing_cert.sh <path-to-.p12>

set -e

CERT_NAME="WisprWave Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
OUT="${1:-WisprWave-signing.p12}"

# `-v` only lists trusted identities; a self-signed cert isn't trusted by policy, so
# we use the unfiltered listing to detect existence.
if ! security find-identity -p codesigning "$KEYCHAIN" | grep -q "$CERT_NAME"; then
    echo "❌ Identity '$CERT_NAME' not found in your login keychain."
    echo "   Run ./create_signing_cert.sh first to create it."
    exit 1
fi

# `security export -t identities` exports ALL identities in the keychain — it has no
# name filter. Warn if there's more than one so the user isn't surprised.
COUNT=$(security find-identity -p codesigning "$KEYCHAIN" \
        | awk '/^[[:space:]]*[0-9]+ identities found/ {print $1; exit}')
if [ "${COUNT:-0}" -gt 1 ]; then
    echo "⚠️  Your login keychain has $COUNT code-signing identities; 'security export'"
    echo "    will write all of them into the .p12. Continue? [y/N]"
    read -r ans
    [[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
fi

if [ -e "$OUT" ]; then
    echo "❌ '$OUT' already exists. Refusing to overwrite. Pass a different path."
    exit 1
fi

echo "Choose a passphrase to protect the .p12 (you'll need it on restore)."
read -r -s -p "Passphrase: " PASS; echo
read -r -s -p "Confirm:    " PASS2; echo
[ "$PASS" = "$PASS2" ] || { echo "❌ Passphrases don't match."; exit 1; }
[ -n "$PASS" ] || { echo "❌ Passphrase cannot be empty."; exit 1; }

security export -k "$KEYCHAIN" -t identities -f pkcs12 -P "$PASS" -o "$OUT"

echo ""
echo "✅ Exported to $OUT"
echo "   • Back this file up securely (password manager / encrypted backup)."
echo "   • Do NOT commit it to a public repo."
echo "   • To restore on another Mac:  ./create_signing_cert.sh $OUT"
