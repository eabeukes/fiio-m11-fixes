#!/usr/bin/env bash
# Install module/ as the Magisk module m11-props on the M11 (adb shell has su), then reboot.
# Remove: adb shell su -c 'touch /data/adb/modules/m11-props/remove' && adb reboot
set -euo pipefail
cd "$(dirname "$0")"
export MSYS_NO_PATHCONV=1
adb shell rm -rf /data/local/tmp/m11-props
adb push module /data/local/tmp/m11-props >/dev/null
adb shell su -c "'
set -e
M=/data/adb/modules/m11-props
rm -rf \$M
cp -r /data/local/tmp/m11-props \$M
rm -rf /data/local/tmp/m11-props
chown -R 0:0 \$M
chmod 0755 \$M \$M/post-fs-data.sh
chmod 0644 \$M/module.prop
echo installed \$M
'"
