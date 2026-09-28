#!/usr/bin/env python3
"""List the entries that differ between two PlangOS tarballs (for check 1.5).

usage: tardiff.py <a.tar.xz> <b.tar.xz>
"""
import hashlib
import sys
import tarfile


def index(path):
    out = {}
    with tarfile.open(path) as t:
        for m in t:
            h = ""
            if m.isfile():
                h = hashlib.sha256(t.extractfile(m).read()).hexdigest()[:16]
            out[m.name] = (m.type, m.mode, m.uid, m.gid, m.mtime, m.size, m.linkname, h)
    return out


a, b = index(sys.argv[1]), index(sys.argv[2])
diff = sorted(n for n in a.keys() | b.keys() if a.get(n) != b.get(n))
for n in diff:
    print(n)
    print("   a:", a.get(n))
    print("   b:", b.get(n))
print(f"{len(diff)} differing entries of {len(a)}")
sys.exit(1 if diff else 0)
