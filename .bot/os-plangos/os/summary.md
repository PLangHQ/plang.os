# os bot — branch `os/plangos`

## Version
v3 (2026-10-14). Installed in /shared/plangos: image 07aeec3c (fallback image.last 224a46fe), runtime b7bb7e11c.

## What this is
PlangOS: a WSL distro where only PLang runs (C# Wayland compositor + Chromium), shown on Windows by plang.exe.
This version: what the person changes in PlangOS's own apps survives a new image, and the bot box (☰) behaves.

## What was done
- **Your app survives (v3).** A new image replaces /opt/plang/os; only /home/plang (data.vhd) is kept. Claude's first
  change to an app that comes with PlangOS (WriteFile from that app's window ☰) copies the app to /app/<name>
  (= /home/plang/app/<name>), keeps the original in /app/.base/<name>, writes the change in the copy and navigates the
  window to it. Writer opens from /app/writer when it exists. WriteFile into /system/plangos/app/ (the desktop box)
  is refused with why. Files: Screen.goal (Edit, OwnWriter, ChangesApp, OwnApp, CopyApp, ShowOwnApp),
  agent/WriteFile.goal (NotHere). Tested on the Linux harness (ownapptest.sh): copy, base, change, window, re-open,
  load and save from the copy.
- **Bot box (v2→image 224a46fe):** closes on a click elsewhere (page blur; the box gives the desktop the keyboard),
  ☰ opens in one click, what is written while Claude works is queued. desktop.html.
- **Modal questions: withdrawn.** window.ask + %askWindow% were rejected by Ingi: the asker just asks; the input
  channel's goal (Question) must get *who asked* from plang. Proposal with the architect ("a question knows who
  asked", next branch). The display Sheet.cs is on local plang branch plang-os-sheet (e95b20b72).
- plang branch plang-os-stable sits on runtime2 (app-systems closed, decision 743); nothing to merge.

## Open
- Stop button for the bot (cancel the turn + end claude on the host).
- Compare /app/.base/<name> with a newer image's app and tell the person (not built yet).
- plang bug reported: file.exists(Path=%var%) answers text, never empty; workaround Path="%x%/".
- ShellUpdate's %file!relative% bug: shell.next doesn't work; ship through images.

## Code example
```
OwnApp
- set %ownApp% to %claudeApp.replace("/system/plangos/app/", "/app/")%
- file.exists(Path="%ownApp%/"); variable.set(Name=%owned%, Value=%!data%)
- condition.if(Left=%owned%, Operator="isempty") { goal.call(Name="CopyApp") }
- set %ownPath% to %call.parameters.path.replace("/system/plangos/app/", "/app/")%
```

## After review (v2)
Ingi: "window.ask hljómar rangt" — a second verb beside `ask`, and the shell storing which window asked. Withdrawn;
the question should carry who asked (plang core change, with the architect).
