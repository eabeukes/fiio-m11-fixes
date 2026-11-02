#!/usr/bin/env python3
"""Whole-file sign a recovery zip the way AOSP `signapk -w` does, then check it.

The M11's stock recovery (and RecoverySystem.verifyPackage) trusts only the AOSP testkey,
which is SHA-1/RSA-2048/e=3, so the signature is PKCS#7 over SHA-1 with no signed attributes.

Layout (bootable/recovery/verifier.cpp, Android 7):
  signed bytes = the whole file except the EOCD comment-length field and the comment
  comment      = <PKCS#7 DER> <sig_start:u16> ff ff <comment_len:u16>, sig_start == comment_len

usage: sign-ota.py <in.zip> <out.zip> <testkey.x509.pem> <testkey.key.pem>
"""
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

EOCD = b"PK\x05\x06"


def openssl(*args, data=None):
    return subprocess.run(["openssl", *args], input=data, capture_output=True, check=True).stdout


def sign(zip_bytes, cert, key):
    if zip_bytes[-22:-18] != EOCD or zip_bytes[-2:] != b"\0\0":
        sys.exit("input must be a zip with no comment")
    signed = zip_bytes[:-2]
    with tempfile.TemporaryDirectory() as d:
        src = Path(d, "signed")
        src.write_bytes(signed)
        sig = openssl("cms", "-sign", "-binary", "-noattr", "-nosmimecap", "-md", "sha1",
                      "-outform", "DER", "-signer", cert, "-inkey", key, "-in", str(src))
    total = len(sig) + 6
    comment = sig + struct.pack("<H", total) + b"\xff\xff" + struct.pack("<H", total)
    if EOCD in comment:
        sys.exit("signature contains an EOCD marker; recovery would reject it")
    return signed + struct.pack("<H", total) + comment


def verify(data, cert):
    """Mirror verifier.cpp's checks, then verify the signature itself."""
    comment_size, = struct.unpack("<H", data[-2:])
    sig_start, = struct.unpack("<H", data[-6:-4])
    assert data[-4:-2] == b"\xff\xff", "no signature footer"
    eocd_size = comment_size + 22
    eocd = data[-eocd_size:]
    assert eocd[:4] == EOCD, "EOCD not where the comment length says"
    assert eocd.count(EOCD) == 1, "extra EOCD marker in the comment"
    sig = eocd[eocd_size - sig_start:eocd_size - 6]
    signed = data[:len(data) - comment_size - 2]

    with tempfile.TemporaryDirectory() as d:
        Path(d, "sig").write_bytes(sig)
        Path(d, "signed").write_bytes(signed)
        asn = openssl("asn1parse", "-inform", "DER", "-in", str(Path(d, "sig"))).decode()
        assert "pkcs9" not in asn and "contentType" not in asn, "signed attributes present"
        assert ":sha1" in asn, "digest is not SHA-1"
        openssl("cms", "-verify", "-binary", "-inform", "DER", "-in", str(Path(d, "sig")),
                "-content", str(Path(d, "signed")), "-certfile", cert, "-noverify",
                "-out", "/dev/null")


def main():
    src, dst, cert, key = sys.argv[1:5]
    out = sign(Path(src).read_bytes(), cert, key)
    verify(out, cert)
    Path(dst).write_bytes(out)
    print(f"{dst}: {len(out)} bytes, signature verified")


if __name__ == "__main__":
    main()
