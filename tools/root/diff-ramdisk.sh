#!/usr/bin/env bash
# Unpack root/out/ramdisk-{stock,magisk}.uimg and show what Magisk changed.
set -euo pipefail
R=$(cd "$(dirname "$0")" && pwd)/out
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
for n in stock magisk; do
  mkdir "$T/$n"
  # cpio can't create the dev nodes as non-root; everything else extracts
  tail -c +65 "$R/ramdisk-$n.uimg" | gzip -dc | (cd "$T/$n" && cpio -idm --no-absolute-filenames 2>/dev/null) || true
done
cd "$T"
chmod -R u+rwX . 2>/dev/null || true
diff -rq stock magisk || true
echo ---
for n in stock magisk; do
  tail -c +65 "$R/ramdisk-$n.uimg" | gzip -dc | cpio -tv 2>/dev/null | grep -E "sbin/(ueventd|watchdogd)|fstab\.samsung" || true
done
echo ---
tail -c +65 "$R/ramdisk-magisk.uimg" | gzip -dc | cpio -tv 2>/dev/null | grep -E " init$| \.backup| overlay"
file magisk/init
