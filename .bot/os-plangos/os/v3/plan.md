# v3 — the person's own apps survive a new image

Ingi (2026-10-14): his changes to Writer (the app itself) were lost when a new image replaced
/opt/plang/os. "we need to make it survivable" → agreed design: "my own app/writer folder".

## Design
- Apps that come with PlangOS stay in the image: /system/plangos/app/<name>.
- The first change Claude makes to one (WriteFile from that app's window ☰) copies it to the
  person's app, /app/<name> (= /home/plang/app/<name>, on data.vhd), and the change goes there.
  The original is also kept as /app/.base/<name> — what the copy came from, to compare with a
  newer image's version later.
- The window then shows the copy; Claude's later paths are in the copy (the box takes the app from the page).
- Writer opens from the person's copy when there is one (Edit).
- A write into /system/plangos/app/ that isn't from the app's own window (the desktop's box) is refused
  with why: change an app from its window, so it becomes the person's.

## Files
- plangos/rootfs/opt/plang/os/system/plangos/Screen.goal (Edit, RunCall, OwnApp…)
- agent/instructions.md (desktop variant: how to change an app)

## Test
Linux harness: open Writer, Claude-style WriteFile call through RunCall → /home/plang/app/writer exists,
window on file:///home/plang/app/writer/start.html, change there, system copy untouched; Edit opens the copy.
