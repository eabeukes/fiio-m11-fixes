#!/usr/bin/env bash
# For each host, fetch the chain it serves and verify it against (a) the M11's stock CA
# store and (b) the module's store, which replaces it (AOSP's current roots only).
# Run in Linux or WSL:  bash tools/cacerts/check-chains.sh [host...]
set -uo pipefail
cd "$(dirname "$0")"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cat device/* > "$T/before.pem"
cat module/system/etc/security/cacerts/*.[0-9] > "$T/after.pem"
hosts=("$@")
[ ${#hosts[@]} -gt 0 ] || hosts=(valid-isrgrootx1.letsencrypt.org valid-isrgrootx2.letsencrypt.org
  www.google.com www.youtube.com tidal.com www.qobuz.com open.spotify.com api.spotify.com
  www.amazon.com music.amazon.com www.microsoft.com github.com www.head-fi.org www.fiio.com
  apkpure.com raw.githubusercontent.com)
printf '%-36s %-8s %-8s %s\n' host stock fixed root
for h in "${hosts[@]}"; do
  openssl s_client -connect "$h:443" -servername "$h" -showcerts </dev/null 2>/dev/null \
    | awk -v d="$T" '/BEGIN CERT/{n++; f=sprintf("%s/c%02d.pem", d, n); in_cert=1} in_cert{print > f} /END CERT/{in_cert=0; close(f)}'
  [ -f "$T/c01.pem" ] || { printf '%-36s %s\n' "$h" "no connection"; continue; }
  cat "$T"/c0[2-9].pem "$T"/c1*.pem 2>/dev/null > "$T/inter.pem"
  v() { openssl verify -no-CAfile -no-CApath -no-CAstore -CAfile "$1" -untrusted "$T/inter.pem" "$T/c01.pem" >/dev/null 2>&1 && echo ok || echo FAIL; }
  root=$(openssl verify -show_chain -no-CAfile -no-CApath -no-CAstore -CAfile "$T/after.pem" -untrusted "$T/inter.pem" "$T/c01.pem" 2>/dev/null \
    | grep -E '^depth=[0-9]+:' | tail -1 | sed 's/.*CN *= *//; s/,.*//')
  printf '%-36s %-8s %-8s %s\n' "$h" "$(v "$T/before.pem")" "$(v "$T/after.pem")" "$root"
  rm -f "$T"/c*.pem
done
