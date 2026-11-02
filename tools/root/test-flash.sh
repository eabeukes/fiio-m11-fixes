#!/usr/bin/env bash
# Run the update-binaries from out/m11-root.zip and out/m11-restore-ramdisk.zip under
# qemu against a fake 10 MiB ramdisk partition (private mount namespace, no real devices).
# Run in Linux or WSL:  bash tools/root/test-flash.sh   (needs qemu-user-static)
set -euo pipefail
cd "$(dirname "$0")"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
for z in m11-root m11-restore-ramdisk; do
  python3 -I -c 'import sys,zipfile; open(sys.argv[2],"wb").write(zipfile.ZipFile(sys.argv[1]).read("META-INF/com/google/android/update-binary"))' \
    "out/$z.zip" "$T/$z"
  chmod +x "$T/$z"
done
cp out/ramdisk-stock.uimg out/ramdisk-magisk.uimg "$T/"

unshare -mr bash -s "$T" <<'EOF'
set -u
T=$1
mount -t tmpfs t /sys/class/block
mkdir /sys/class/block/mmcblk0p10
printf 'MAJOR=259\nMINOR=2\nDEVNAME=mmcblk0p10\nDEVTYPE=partition\nPARTN=10\nPARTNAME=ramdisk\n' > /sys/class/block/mmcblk0p10/uevent
head -c $((10 << 20)) /dev/urandom > "$T/rand"   # before /dev is hidden
mount -t tmpfs t /dev
mkdir -p /dev/block
DEV=/dev/block/mmcblk0p10
fill() { cp "$T/rand" $DEV; [ -n "${1:-}" ] && dd if="$1" of=$DEV conv=notrunc status=none; true; }
has() { cmp -s -n "$(stat -c %s "$1")" "$1" $DEV; }
run() { qemu-aarch64-static "$T/$1" 3 1 /fake.zip | sed -n 's/^ui_print \(.\)/    \1/p'; return ${PIPESTATUS[0]}; }
check() { if eval "$2"; then echo "PASS  $1"; else echo "FAIL  $1"; FAILED=1; fi; }
FAILED=0

echo "1) root on stock"; fill "$T/ramdisk-stock.uimg"; run m11-root; rc=$?
check "rc 0 and Magisk written" "[ $rc = 0 ] && has $T/ramdisk-magisk.uimg"
echo "2) root again"; run m11-root; rc=$?
check "rc 0, still Magisk" "[ $rc = 0 ] && has $T/ramdisk-magisk.uimg"
echo "3) root on unknown contents"; fill; cp $DEV $T/before; run m11-root; rc=$?
check "rc 1, partition untouched" "[ $rc = 1 ] && cmp -s $T/before $DEV"
echo "4) restore on Magisk"; fill "$T/ramdisk-magisk.uimg"; run m11-restore-ramdisk; rc=$?
check "rc 0 and stock written" "[ $rc = 0 ] && has $T/ramdisk-stock.uimg"
echo "5) restore on stock"; run m11-restore-ramdisk; rc=$?
check "rc 0, still stock" "[ $rc = 0 ] && has $T/ramdisk-stock.uimg"
echo "6) restore on unknown contents"; fill; run m11-restore-ramdisk; rc=$?
check "rc 0 and stock written" "[ $rc = 0 ] && has $T/ramdisk-stock.uimg"
echo "7) wrong partition name"; sed -i 's/PARTNAME=ramdisk/PARTNAME=kernel/' /sys/class/block/mmcblk0p10/uevent
fill "$T/ramdisk-stock.uimg"; cp $DEV $T/before; run m11-root; rc=$?
check "rc 1, partition untouched" "[ $rc = 1 ] && cmp -s $T/before $DEV"
exit $FAILED
EOF
