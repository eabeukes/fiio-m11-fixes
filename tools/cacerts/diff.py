#!/usr/bin/env python3
"""Compare the device's cacerts with AOSP's current store by SHA-256 fingerprint.

usage: diff.py <aosp-dir> <device-dir>
"""
import sys
from datetime import datetime, timezone
from pathlib import Path

from cryptography import x509
from cryptography.hazmat.primitives import hashes


def load(d):
    out = {}
    for f in sorted(Path(d).iterdir()):
        cert = x509.load_pem_x509_certificate(f.read_bytes())
        out[cert.fingerprint(hashes.SHA256())] = (f.name, cert)
    return out


def cn(cert):
    for oid in (x509.NameOID.COMMON_NAME, x509.NameOID.ORGANIZATIONAL_UNIT_NAME, x509.NameOID.ORGANIZATION_NAME):
        a = cert.subject.get_attributes_for_oid(oid)
        if a:
            return a[0].value
    return cert.subject.rfc4514_string()


aosp, device = load(sys.argv[1]), load(sys.argv[2])
now = datetime.now(timezone.utc)
missing = [v for k, v in aosp.items() if k not in device]
removed = [v for k, v in device.items() if k not in aosp]
print(f"AOSP {len(aosp)}, device {len(device)}, in both {len(set(aosp) & set(device))}")
print(f"\nMissing on device ({len(missing)}):")
for name, c in sorted(missing, key=lambda v: cn(v[1])):
    print(f"  {name:12} {cn(c)}  (until {c.not_valid_after.replace(tzinfo=timezone.utc):%Y-%m})")
print(f"\nOn device but no longer in AOSP ({len(removed)}):")
for name, c in sorted(removed, key=lambda v: cn(v[1])):
    expired = " EXPIRED" if c.not_valid_after.replace(tzinfo=timezone.utc) < now else ""
    print(f"  {name:12} {cn(c)}  (until {c.not_valid_after.replace(tzinfo=timezone.utc):%Y-%m}){expired}")
