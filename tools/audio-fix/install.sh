#!/usr/bin/env bash
# Build module/system/lib64/libmedia.so from the stock library and install the Magisk module
# m11-static-audiotrack on the M11 (adb shell has su). Reboot afterwards.
# Remove: adb shell su -c 'touch /data/adb/modules/m11-static-audiotrack/remove' && adb reboot
# If Android doesn't come back: hold volume-down while booting (Magisk safe mode disables modules),
# or flash root/out/m11-restore-ramdisk.zip from recovery (Next + power), which removes Magisk.
set -euo pipefail
cd "$(dirname "$0")"
export MSYS_NO_PATHCONV=1
mkdir -p module/system/lib64
cp libmedia64.patched.so module/system/lib64/libmedia.so
adb shell rm -rf /data/local/tmp/m11-static-audiotrack
adb push module /data/local/tmp/m11-static-audiotrack >/dev/null
adb shell su -c "'
set -e
M=/data/adb/modules/m11-static-audiotrack
rm -rf \$M
cp -r /data/local/tmp/m11-static-audiotrack \$M
rm -rf /data/local/tmp/m11-static-audiotrack
chown -R 0:0 \$M
find \$M -type d -exec chmod 0755 {} +
find \$M -type f -exec chmod 0644 {} +
chcon -R u:object_r:system_file:s0 \$M/system
/data/adb/magisk/busybox sha256sum \$M/system/lib64/libmedia.so
'"
