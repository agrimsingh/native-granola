#!/bin/zsh
# Creates a self-signed code-signing identity in signing/dev.keychain-db. Signing every build with
# the same identity lets macOS remember the app's microphone and system-audio permissions across
# rebuilds. Run once; scripts/bundle.sh picks the identity up automatically.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p signing
cd signing

PASSWORD=nativegranola
KEYCHAIN=$PWD/dev.keychain-db
NAME="Native Granola Dev"

if [[ -f identity ]]; then
  echo "Signing identity already set up: $(cat identity)"
  exit 0
fi

cat > cert.cnf <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
openssl req -x509 -newkey rsa:2048 -nodes -keyout dev.key -out dev.crt -days 3650 -config cert.cnf 2>/dev/null
openssl pkcs12 -export -inkey dev.key -in dev.crt -out dev.p12 -passout pass:$PASSWORD -name "$NAME"

security create-keychain -p $PASSWORD "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"
security unlock-keychain -p $PASSWORD "$KEYCHAIN"
security import dev.p12 -k "$KEYCHAIN" -P $PASSWORD -T /usr/bin/codesign -f pkcs12
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k $PASSWORD "$KEYCHAIN" >/dev/null
rm dev.p12

# codesign only finds identities in keychains on the user's search list.
existing=(${(f)"$(security list-keychains -d user | tr -d '" ')"})
security list-keychains -d user -s "${existing[@]}" "$KEYCHAIN"

security find-identity -p codesigning "$KEYCHAIN" | awk '/\)/ {print $2; exit}' > identity
echo "Created signing identity $(cat identity) in $KEYCHAIN"
