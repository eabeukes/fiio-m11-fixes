#!/usr/bin/env bash
# Patch FiiO's 64-bit libmedia.so so static AudioTracks get AOSP's frameCount again.
#
# FiiO's AudioTrack::createTrack_l() sends every track to AudioFlinger with
#   frameCount = min(mAfLatency_ms * sampleRate / 1000, 8192)
# including MODE_STATIC tracks, ignoring the shared buffer's real size. AudioFlinger's
# 38340117 check (sharedBuffer->size() >= frameCount * frameSize) then rejects small static
# tracks with -12 ("no control block"), e.g. ExoPlayer's keep-session-id track, which leaves
# Apple Music silent. This restores  frameCount = sharedBuffer->size() / mFrameSize  on the
# static branch only (0xc05a8..0xc05e0); streaming tracks keep FiiO's computation.
#
# Run in Linux or WSL:  bash tools/audio-fix/make-patch.sh <stock lib64/libmedia.so> <out.so>
set -euo pipefail
IN=$1 OUT=$2
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

cat > "$T/p.s" <<'EOF'
    .text
    .globl _start
_start:                         // 0xc05a8
    cbnz    x8, err             // misaligned buffer -> error (was: cbz x8, c05dc)
    bl      imem_size           // x0 = sharedBuffer->size()   (x0 = mSharedBuffer, set at c05a0)
    ldr     x9, [x19, #496]     // mFrameSize
    udiv    x24, x0, x9         // frameCount = size / mFrameSize
    str     wzr, [sp, #156]     // as at c0614
    ldr     w8, [x19, #672]     // as at c0618
    b       rejoin              // c062c, just after FiiO's csel x24
err:
    mov     w8, #-22            // BAD_VALUE, as at c05d0
    stur    w8, [x29, #-108]
    b       fail                // c02c0
    nop                         // 0xc05d0 .. 0xc05e0: no longer reached
    nop
    nop
    nop
    nop                         // ends at 0xc05e4 (exclusive)
EOF
aarch64-linux-gnu-as -o "$T/p.o" "$T/p.s"
aarch64-linux-gnu-ld -o "$T/p.elf" -Ttext=0xc05a8 \
  --defsym=imem_size=0xb94d0 --defsym=rejoin=0xc062c --defsym=fail=0xc02c0 "$T/p.o"
aarch64-linux-gnu-objcopy -O binary -j .text "$T/p.elf" "$T/p.bin"

python3 -I - "$IN" "$OUT" "$T/p.bin" <<'EOF'
import sys, hashlib
src, dst, binf = sys.argv[1:4]
data = bytearray(open(src, 'rb').read())
patch = open(binf, 'rb').read()
VA, LOAD_VA, LOAD_OFF = 0xc05a8, 0x65000, 0x0        # first PT_LOAD: vaddr 0x65000 at file offset 0
off = VA - LOAD_VA + LOAD_OFF
assert len(patch) == 0xc05e4 - VA, len(patch)
# Only the exact library analysed (/system/lib64/libmedia.so, FiiO M11 FW 1.1.1, 2020-12-30 build).
STOCK = 'c7933a37ed80c7ff7d9e1c720fc33a258cc5478630c97955c3476dd5feceeefb'
assert hashlib.sha256(data).hexdigest() == STOCK, 'not the analysed stock libmedia.so'
open(dst, 'wb').write(data[:off] + patch + data[off + len(patch):])
print(f'patched {len(patch)} bytes at file offset {off:#x}')
EOF
sha256sum "$IN" "$OUT"
