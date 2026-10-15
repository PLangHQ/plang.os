# v4 — two asks from Ingi (2026-10-14/15), separate branches

## 1. PlangOS runs PowerShell/shell on the Windows host

Ingi's answers: any plang app in PlangOS may ask; PlangOS's own goals are never asked; another app's
command is asked (y/n/a, 'a' remembered).

Path: PlangOS shell → %!app.parent.goal["Shell"]% → host ChildCalls → /child/Shell.goal →
terminal.start(App="powershell.exe", Parameter=["-NoProfile", "-NonInteractive", "-Command", %command%]).
Answer back: {output, error, exitCode}. Every command logged on the host (hostshell.jsonl: at, who, command, exit).

Blocked on the architect (design ask sent 2026-10-15):
- the host's execute permission for powershell: a standing grant from host setup (new core action) vs one 'a'
  answered on the PlangOS screen;
- telling PlangOS's own goals from an app: "a question knows who asked" (architect's next branch).

Branch: plang.os `os/host-shell` (shell + host goals); plang `plang-os-host-shell` only if core is needed.

## 2. Run external programs safely ("as safe as possible")

Ingi: any program (binaries, scripts), inside PlangOS, locked down.

Have: terminal.start Permission=[…] → Landlock (files: only the granted folders + system libs; fails closed).
Missing, layer by layer (each fails closed, like Landlock):
1. **Own identity**: a user namespace (unshare CLONE_NEWUSER) mapping to an unprivileged uid → the program can't
   signal or ptrace plang, and owns nothing of plang's.
2. **Own view**: PID + IPC + UTS + mount namespaces → sees only its own processes; /proc is its own.
3. **No network** by default: a network namespace with only loopback; a grant opens it (later: an allowlist
   through a proxy owned by plang).
4. **Syscall filter** (seccomp-bpf): deny ptrace, mount, bpf, kexec, keyctl, perf_event_open, userfaultfd,
   unshare/setns (no escaping its namespaces), module loading; no_new_privs (no setuid gain).
5. **Limits** (cgroup v2): memory.max, cpu.max, pids.max, and a wall-clock timeout → a fork bomb or a hog
   can't take PlangOS (or Ingi's laptop) down.
6. **Files**: Landlock as today + a private writable /tmp in its own folder, wiped after.
Measure first: strace -c of real programs (python, node, a static binary) to set the seccomp list; try to escape
each layer (signal plang, read /proc/1/environ, open a socket, fork bomb, write outside) — each must fail.

Shape in plang: terminal.start gains these as the default of a held program (Permission given) — or a setting
"sandboxed". Core change (terminal module) → architect's ruling before building.

Branch: plang `plang-os-sandbox` (terminal module), plang.os for the image (needs no new packages: all kernel).
