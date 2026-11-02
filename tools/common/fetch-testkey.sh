#!/usr/bin/env bash
# Download the public AOSP test key into keys/ and check it is the key the M11's recovery trusts.
# FiiO signs M11 firmware with this key, so recovery accepts any package signed with it.
#   bash tools/common/fetch-testkey.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p keys
URL=https://android.googlesource.com/platform/build/+/refs/heads/main/target/product/security
for f in testkey.pk8 testkey.x509.pem; do
  curl -sSfL "$URL/$f?format=TEXT" | base64 -d > "keys/$f"
done
openssl pkcs8 -inform DER -nocrypt -in keys/testkey.pk8 -out keys/testkey.key.pem
fp=$(openssl x509 -in keys/testkey.x509.pem -noout -fingerprint -sha1 | cut -d= -f2)
[ "$fp" = "61:ED:37:7E:85:D3:86:A8:DF:EE:6B:86:4B:D8:5B:0B:FA:A5:AF:81" ] \
  || { echo "unexpected testkey fingerprint $fp"; exit 1; }
echo "keys/ ready (AOSP testkey, SHA-1 $fp)"
