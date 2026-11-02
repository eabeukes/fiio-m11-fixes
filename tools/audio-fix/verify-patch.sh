#!/usr/bin/env bash
# Show every instruction that differs between stock and patched libmedia.so (whole .text),
# then the patched static branch in context.
# Run in Linux or WSL:  bash tools/audio-fix/verify-patch.sh <stock.so> <patched.so>
set -euo pipefail
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
for f in "$1" "$2"; do
  aarch64-linux-gnu-objdump -d --no-show-raw-insn "$f" | sed 's/<[^>]*>//g' | tail -n +4 > "$T/$(basename "$f").dis"
done
{ cmp -l "$1" "$2" || true; } | awk '{printf "%x\n", $1-1}' | sed -n '1p;$p' | paste -sd' ' | sed 's/^/changed file bytes: first,last = /'
echo "changed bytes: $({ cmp -l "$1" "$2" || true; } | wc -l)"
diff "$T/$(basename "$1").dis" "$T/$(basename "$2").dis" || true
echo "=== patched region in context"
aarch64-linux-gnu-objdump -d --no-show-raw-insn --start-address=0xc0590 --stop-address=0xc0640 "$2" | tail -n +7 | sed 's/<_ZN7android10AudioTrack13createTrack_lEv@@Base+/<+/'
