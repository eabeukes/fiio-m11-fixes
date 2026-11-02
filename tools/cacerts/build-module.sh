#!/usr/bin/env bash
# Fill module/system/etc/security/cacerts with AOSP's current root store and mark it .replace,
# so Magisk swaps in the whole directory. Uses AOSP's own file names (<subject_hash_old>.N);
# Android stops looking at the first missing .N, so never delete single files instead.
#   bash tools/cacerts/build-module.sh
set -euo pipefail
cd "$(dirname "$0")"
URL=https://android.googlesource.com/platform/system/ca-certificates/+archive/refs/heads/main/files.tar.gz
rm -rf aosp && mkdir aosp
curl -sSfL "$URL" | tar -xz -C aosp
C=module/system/etc/security/cacerts
mkdir -p "$C"
rm -f "$C"/*
cp aosp/* "$C"/
touch "$C/.replace"
echo "$(ls "$C" | wc -l) roots in $C"
