# A Linux host for PlangOS (testing)

What the Windows host's OpenPlangOS does, on Linux: `screen.open` gives a **view** (the screen kind for a Linux host,
no window) that shows what PlangOS sends — frames, moves, QOI, video through openh264 — and PlangOS runs from an
unpacked image through `plangos.sh` instead of wsl.exe. This app's input lines are the person's input
(`{"mouse":…}`, `{"key":…}`, `{"text":…}`), going down to PlangOS; their end closes it. `Shot` saves what the host
shows (`shot.png`) 25 s in.

```sh
PLANGOS_ROOT=<rootfs> RUN_LOCAL=<run-local.sh> LD_LIBRARY_PATH=<dir with libopenh264.so.8> plang Start < input-fifo
```
