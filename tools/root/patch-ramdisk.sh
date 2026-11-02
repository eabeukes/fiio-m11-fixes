#!/usr/bin/env bash
# Patch the M11's stock ramdisk partition image with Magisk, the way Magisk's own
# boot_patch.sh does for a legacy (non system-as-root) ramdisk. Kernel is not touched:
# it has none of the Samsung RKP/DEFEX/PROCA patterns boot_patch.sh hexpatches.
#
# The ramdisk partition holds a u-boot legacy uImage ("ramdisk", load 0x40800000,
# comp=none) wrapping a gzip cpio. U-Boot checks both header and data CRC.
#
# Run in Linux or WSL:
#   bash tools/root/patch-ramdisk.sh <backup-dir>/ramdisk.img <Magisk-v30.7.apk>
# Output:  tools/root/out/ramdisk-stock.uimg, tools/root/out/ramdisk-magisk.uimg
set -euo pipefail
[ $# -eq 2 ] || { echo "usage: $0 <backup>/ramdisk.img <Magisk.apk>"; exit 2; }
STOCK=$(realpath "$1")
APK=$(realpath "$2")
cd "$(dirname "$0")"
W=out/work
mkdir -p out
rm -rf out/*
mkdir -p "$W"

# Magisk's own binaries from the APK: x86_64 magiskboot runs here, the arm64 ones go in the ramdisk.
python3 -I - "$APK" "$W" <<'EOF'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
for src, dst in [('lib/x86_64/libmagiskboot.so', 'magiskboot'), ('lib/arm64-v8a/libmagiskinit.so', 'magiskinit'),
                 ('lib/arm64-v8a/libmagisk.so', 'magisk'), ('lib/arm64-v8a/libinit-ld.so', 'init-ld'),
                 ('assets/stub.apk', 'stub.apk')]:
    open(f'{sys.argv[2]}/{dst}', 'wb').write(z.read(src))
EOF
chmod +x "$W/magiskboot"

python3 -I - "$STOCK" out/ramdisk-stock.uimg "$W/ramdisk.cpio.gz" <<'EOF'
import sys, struct, zlib
img = open(sys.argv[1], 'rb').read()
hdr = bytearray(img[:64])
magic, hcrc, _, size, _, _, dcrc = struct.unpack('>IIIIIII', hdr[:28])
assert magic == 0x27051956, 'not a uImage'
data = img[64:64 + size]
check = hdr[:]; check[4:8] = b'\0\0\0\0'
assert zlib.crc32(check) == hcrc, 'stock header CRC mismatch'
assert zlib.crc32(data) == dcrc, 'stock data CRC mismatch'
open(sys.argv[2], 'wb').write(img[:64 + size])
open(sys.argv[3], 'wb').write(data)
print(f'stock uImage: {size} bytes payload, CRCs ok')
EOF

cd "$W"
gzip -dc ramdisk.cpio.gz > ramdisk.cpio
rc=0; ./magiskboot cpio ramdisk.cpio test || rc=$?
[ $rc -eq 0 ] || { echo "ramdisk is not stock (test=$rc)"; exit 1; }
cp ramdisk.cpio ramdisk.cpio.orig

./magiskboot compress=xz magisk magisk.xz
./magiskboot compress=xz stub.apk stub.xz
./magiskboot compress=xz init-ld init-ld.xz
# PREINITDEVICE is what `magisk --preinit-device` prints on an M11 (userdata, mmcblk0p3). Without
# it the app nags "Recovery mode cannot get correct device info" and offers a reinstall that
# would go looking for a boot partition this device doesn't have.
cat > config <<EOF
KEEPVERITY=false
KEEPFORCEENCRYPT=false
RECOVERYMODE=false
VENDORBOOT=false
PREINITDEVICE=mmcblk0p3
SHA1=$(sha1sum "$STOCK" | cut -d' ' -f1)
EOF

./magiskboot cpio ramdisk.cpio \
  "add 0750 init magiskinit" \
  "mkdir 0750 overlay.d" \
  "mkdir 0750 overlay.d/sbin" \
  "add 0644 overlay.d/sbin/magisk.xz magisk.xz" \
  "add 0644 overlay.d/sbin/stub.xz stub.xz" \
  "add 0644 overlay.d/sbin/init-ld.xz init-ld.xz" \
  "patch" \
  "backup ramdisk.cpio.orig" \
  "mkdir 000 .backup" \
  "add 000 .backup/.magisk config"

rc=0; ./magiskboot cpio ramdisk.cpio test || rc=$?
[ $rc -eq 1 ] || { echo "patched ramdisk not recognised as Magisk (test=$rc)"; exit 1; }
gzip -9 -n -c ramdisk.cpio > ramdisk-magisk.cpio.gz
cd ../..

python3 -I - out/ramdisk-stock.uimg "$W/ramdisk-magisk.cpio.gz" out/ramdisk-magisk.uimg <<'EOF'
import sys, struct, zlib, time
stock = open(sys.argv[1], 'rb').read()
data = open(sys.argv[2], 'rb').read()
hdr = bytearray(stock[:64])              # keep load/entry/os/arch/type/comp/name
struct.pack_into('>I', hdr, 4, 0)
struct.pack_into('>I', hdr, 8, int(time.time()))
struct.pack_into('>I', hdr, 12, len(data))
struct.pack_into('>I', hdr, 24, zlib.crc32(data))
struct.pack_into('>I', hdr, 4, zlib.crc32(hdr))
out = bytes(hdr) + data
assert len(out) <= 0xA00000, 'too big for the 10 MiB ramdisk partition / bootcmd read'
open(sys.argv[3], 'wb').write(out)
print(f'magisk uImage: {len(data)} bytes payload ({len(out) / 2**20:.2f} MiB of 10)')
EOF
rm -rf "$W"
sha256sum out/*.uimg
