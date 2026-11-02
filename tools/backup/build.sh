#!/usr/bin/env bash
# Build and sign m11-backup.zip (run in Linux or WSL, from anywhere):
#   bash tools/backup/build.sh
set -euo pipefail
cd "$(dirname "$0")"
KEYS=../../keys

aarch64-linux-gnu-gcc -static -O2 -Wall -Wno-format-truncation -o update-binary update-binary.c
aarch64-linux-gnu-strip update-binary

rm -rf out && mkdir -p out/META-INF/com/google/android
cp update-binary out/META-INF/com/google/android/update-binary
echo "# unused: update-binary is a native program" > out/META-INF/com/google/android/updater-script
# FiiO's recovery aborts unless pre-product matches ro.product.name
# ("try_update_binary failed because product name do not match").
mkdir -p out/META-INF/com/android
printf 'pre-device=maestro7872\npre-product=M11\n' > out/META-INF/com/android/metadata
python3 -I -c '
import sys, zipfile
with zipfile.ZipFile("unsigned.zip", "w", zipfile.ZIP_DEFLATED) as z:
    for f in ("google/android/update-binary", "google/android/updater-script", "android/metadata"):
        z.write("out/META-INF/com/" + f, "META-INF/com/" + f)'

python3 ../common/sign-ota.py unsigned.zip m11-backup.zip "$KEYS/testkey.x509.pem" "$KEYS/testkey.key.pem"
rm -rf out unsigned.zip
sha256sum m11-backup.zip
