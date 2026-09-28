#!/usr/bin/env python3
"""PlangOS image checks that run without Windows (start.md checks 1.4, 1.6 + build sanity).

usage: checks.py <rootfs-dir> <plangos-amd64.tar.xz> [max-MB]

Every check prints PASS/FAIL with the evidence. Exit 1 if any check fails.
Needs objdump (binutils) on the build machine for the ELF check.
"""
import configparser
import os
import stat
import subprocess
import sys
import tarfile

results = []


def check(name, ok, evidence=""):
    results.append(ok)
    print(f"{'PASS' if ok else 'FAIL'}  {name}")
    if evidence:
        for line in evidence.rstrip().splitlines():
            print(f"      {line}")


def files(root):
    for dirpath, dirnames, filenames in os.walk(root):
        for n in filenames:
            yield os.path.join(dirpath, n)


def main(root, tgz, max_mb):
    rel = lambda p: "/" + os.path.relpath(p, root)

    # --- 1.6 size -----------------------------------------------------------------
    mb = os.path.getsize(tgz) / 1e6
    check(f"1.6 compressed image <= {max_mb} MB", mb <= max_mb, f"{os.path.basename(tgz)}: {mb:.1f} MB")

    # --- 1.4 seal: nothing that runs as or becomes someone else -------------------
    with tarfile.open(tgz) as t:
        members = t.getmembers()
    suid = [m.name for m in members if m.mode & (stat.S_ISUID | stat.S_ISGID) and not m.isdir()]
    check("1.4 no setuid/setgid files in the tarball", not suid, "\n".join(suid))

    wrong_owner = [m.name for m in members
                   if (m.uid, m.gid) != (0, 0) and not m.name.startswith("home/plang")]
    check("1.4 everything outside /home/plang is owned by root", not wrong_owner, "\n".join(wrong_owner[:20]))

    writable = [m.name for m in members
                if not m.name.startswith("home/plang") and not m.issym()
                and m.mode & 0o002 and not (m.isdir() and m.mode & 0o1000)]
    check("1.4 no world-writable files or dirs (sticky /tmp excepted)", not writable, "\n".join(writable[:20]))

    shells = ["bin/sh", "bin/bash", "bin/dash", "bin/busybox", "bin/su", "bin/sudo", "bin/login",
              "bin/apt", "bin/apt-get", "bin/dpkg", "bin/perl", "bin/python3", "sbin/unix_chkpwd"]
    present = [s for s in shells if os.path.lexists(os.path.join(root, "usr", s))]
    check("1.4 no shell, su/sudo/login, package manager or interpreter", not present, "\n".join(present))

    exe = []
    for d in ("usr/bin", "usr/sbin", "usr/local/bin"):
        full = os.path.join(root, d)
        if os.path.isdir(full):
            exe += [f"/{d}/{n}" for n in sorted(os.listdir(full))]
    check(f"binaries on PATH: {len(exe)} (each must be justified in attack-surface.md)", True, " ".join(exe))

    with open(os.path.join(root, "etc/passwd")) as f:
        pw = f.read()
    shells_ok = all(line.split(":")[6] == "/opt/plang/plang" for line in pw.strip().splitlines())
    check("1.4 every passwd entry's shell is plang", shells_ok, pw)
    check("1.4 no /etc/shadow (no passwords exist)", not os.path.exists(os.path.join(root, "etc/shadow")))

    wsl = configparser.ConfigParser()
    wsl.read(os.path.join(root, "etc/wsl.conf"))
    for section, key, want in (("interop", "enabled", "false"), ("interop", "appendWindowsPath", "false"),
                               ("automount", "enabled", "false"), ("user", "default", "plang")):
        got = wsl.get(section, key, fallback=None)
        check(f"1.4 wsl.conf [{section}] {key} = {want}", got == want, f"found: {got}")
    check("1.4 wsl.conf has no [boot] command (nothing runs as root at start)",
          not wsl.has_option("boot", "command"))

    # --- every shipped ELF finds its libraries (catches a wrong deny entry) --------
    libdirs = ["usr/lib/x86_64-linux-gnu", "usr/lib", "usr/lib64", "usr/lib/chromium",
               "usr/lib/x86_64-linux-gnu/pulseaudio"]
    have = set()
    for d in libdirs:
        full = os.path.join(root, d)
        if os.path.isdir(full):
            have.update(os.listdir(full))
    missing = {}
    for p in files(root):
        if os.path.islink(p) or not os.path.isfile(p):
            continue
        with open(p, "rb") as f:
            if f.read(4) != b"\x7fELF":
                continue
        out = subprocess.run(["objdump", "-p", p], capture_output=True, text=True).stdout
        needed = [l.split()[1] for l in out.splitlines() if l.strip().startswith("NEEDED")]
        local = set(os.listdir(os.path.dirname(p)))  # $ORIGIN (plang, chromium)
        for n in needed:
            if n not in have and n not in local:
                missing.setdefault(n, []).append(rel(p))
    ev = "\n".join(f"{n} <- {', '.join(v[:3])}{' …' if len(v) > 3 else ''}" for n, v in sorted(missing.items()))
    check("every ELF's NEEDED libraries are in the image", not missing, ev)

    failed = results.count(False)
    print(f"\n{len(results) - failed}/{len(results)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    if len(sys.argv) not in (3, 4):
        sys.exit(__doc__)
    sys.exit(main(sys.argv[1], sys.argv[2], float(sys.argv[3]) if len(sys.argv) == 4 else 300))
