#!/usr/bin/env bash
# Build m11-root.zip and m11-restore-ramdisk.zip from root/out/ramdisk-{stock,magisk}.uimg
# (made by patch-ramdisk.sh). Run in Linux or WSL:
#   bash tools/root/build.sh
set -euo pipefail
cd "$(dirname "$0")"
KEYS=../../keys
OUT=$PWD/out
[ -f out/ramdisk-magisk.uimg ] || { echo "run patch-ramdisk.sh first"; exit 1; }

package() {  # <name> <extra gcc flags...>
  local name=$1; shift
  local d; d=$(mktemp -d)
  aarch64-linux-gnu-gcc -static -O2 -Wall -Wno-unused-result \
    -DSTOCK_IMG="\"$OUT/ramdisk-stock.uimg\"" -DMAGISK_IMG="\"$OUT/ramdisk-magisk.uimg\"" "$@" \
    -o "$d/update-binary" flash-ramdisk.c
  aarch64-linux-gnu-strip "$d/update-binary"
  echo "# unused: update-binary is a native program" > "$d/updater-script"
  # FiiO's recovery aborts unless pre-product matches ro.product.name.
  printf 'pre-device=maestro7872\npre-product=M11\n' > "$d/metadata"
  python3 -I - "$d" "$d/unsigned.zip" <<'EOF'
import sys, zipfile
d, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
    z.write(f'{d}/update-binary', 'META-INF/com/google/android/update-binary')
    z.write(f'{d}/updater-script', 'META-INF/com/google/android/updater-script')
    z.write(f'{d}/metadata', 'META-INF/com/android/metadata')
EOF
  python3 ../common/sign-ota.py "$d/unsigned.zip" "out/$name.zip" "$KEYS/testkey.x509.pem" "$KEYS/testkey.key.pem"
  rm -rf "$d"
}

package m11-root -DROOT
package m11-restore-ramdisk
sha256sum out/*.zip
