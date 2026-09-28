#!/usr/bin/env python3
"""Write a rootfs directory as a deterministic tarball.

Same input tree -> same bytes: entries sorted by path, owners fixed, mtimes set to
SOURCE_DATE_EPOCH, no user/group names, hardlinks kept as links.

Ownership is decided here, not taken from the build machine:
  /home/plang and everything under it -> 10001:10001 (the plang user)
  everything else                     -> 0:0

Refuses (exit 1) if any file has the setuid or setgid bit. PlangOS ships none.

usage: mktar.py <rootfs-dir> <out.tar>
"""
import os
import stat
import sys
import tarfile

PLANG_UID = PLANG_GID = 10001
USER_TREES = ("home/plang",)
MODE_OVERRIDES = {"tmp": 0o1777, "var/tmp": 0o1777, "root": 0o700, "home/plang": 0o750}


def owner(rel):
    for t in USER_TREES:
        if rel == t or rel.startswith(t + "/"):
            return PLANG_UID, PLANG_GID
    return 0, 0


def walk(root):
    out = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for name in dirnames + sorted(filenames):
            out.append(os.path.relpath(os.path.join(dirpath, name), root))
    return sorted(out)


def main(root, dest):
    epoch = int(os.environ["SOURCE_DATE_EPOCH"])
    bad = []
    seen = {}  # (dev, ino) -> first path, for hardlinks
    with tarfile.open(dest, "w", format=tarfile.GNU_FORMAT) as tar:
        for rel in walk(root):
            full = os.path.join(root, rel)
            st = os.lstat(full)
            if st.st_mode & (stat.S_ISUID | stat.S_ISGID) and not stat.S_ISDIR(st.st_mode):
                bad.append(rel)
                continue
            ti = tarfile.TarInfo(rel)
            ti.uid, ti.gid = owner(rel)
            ti.uname = ti.gname = ""
            ti.mtime = epoch
            ti.mode = MODE_OVERRIDES.get(rel, stat.S_IMODE(st.st_mode) & ~(stat.S_ISUID | stat.S_ISGID))
            if stat.S_ISLNK(st.st_mode):
                ti.type = tarfile.SYMTYPE
                ti.linkname = os.readlink(full)
                tar.addfile(ti)
            elif stat.S_ISDIR(st.st_mode):
                ti.type = tarfile.DIRTYPE
                tar.addfile(ti)
            elif stat.S_ISREG(st.st_mode):
                key = (st.st_dev, st.st_ino)
                if st.st_nlink > 1 and key in seen:
                    ti.type = tarfile.LNKTYPE
                    ti.linkname = seen[key]
                    tar.addfile(ti)
                else:
                    seen[key] = rel
                    ti.size = st.st_size
                    with open(full, "rb") as f:
                        tar.addfile(ti, f)
            else:
                bad.append(rel + " (special file)")
    if bad:
        os.remove(dest)
        sys.stderr.write("mktar: refusing setuid/setgid/special files:\n  " + "\n  ".join(bad) + "\n")
        sys.exit(1)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
