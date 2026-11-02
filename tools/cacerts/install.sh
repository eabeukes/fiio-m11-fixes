#!/usr/bin/env bash
# Install module/ as the Magisk module m11-cacerts on the M11 (adb shell has su), then reboot.
# Magisk overlays module/system onto /system at boot; the system partition is not modified.
# Remove: adb shell su -c 'touch /data/adb/modules/m11-cacerts/remove' && adb reboot
set -euo pipefail
cd "$(dirname "$0")"
export MSYS_NO_PATHCONV=1
adb shell rm -rf /data/local/tmp/m11-cacerts
adb push module /data/local/tmp/m11-cacerts >/dev/null
adb shell su -c "'
set -e
M=/data/adb/modules/m11-cacerts
rm -rf \$M
cp -r /data/local/tmp/m11-cacerts \$M
rm -rf /data/local/tmp/m11-cacerts
chown -R 0:0 \$M
find \$M -type d -exec chmod 0755 {} +
find \$M -type f -exec chmod 0644 {} +
chcon -R u:object_r:system_file:s0 \$M/system
echo installed: \$(ls \$M/system/etc/security/cacerts | wc -l) certs in \$M
'"
