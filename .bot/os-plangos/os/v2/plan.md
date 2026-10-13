# v2 — a question is modal on the window that asked (Ingi, 2026-10-13: "fix it properly, modal")

## Why
A permission question in PlangOS showed in the desktop's dialog, lifted above the windows; a click anywhere else
lowered it (the rule made for the start menu), and it went behind the windows. Ingi: a question belongs to the app
that asked — modal inside that app.

## Design
1. **Display (C#, screen module, display kind):** a `Sheet` — a question attached to one window. Drawn right after
   its window (so above it, under windows stacked higher), at the top of the window's content, following the window.
   While it is there, clicks in the window's content go to the sheet (or nowhere), and keys go to it when its window
   has the keyboard; the title bar still moves the window. A permission (the question ends "(y/n/a…)") has three
   buttons — Hafna / Leyfa alltaf / Leyfa einu sinni (n / a / y, as the desktop dialog); any other question a text
   field and Hætta við / Svara. Enter: the default (y, or the typed text); Esc: n, or "". Its answer completes the
   wait; the window closing answers n / "".
2. **Action `window.ask(Window, Question)`** (window module, beside window.call): shows the sheet on that window of
   the browser's screen and waits for the answer; returns the text. New surface — Ingi's go is the request itself.
3. **Shell (Screen.goal, Question):** the window that asked is known where the shell works for a window: a page's
   message (`%asked.from%`, Desktop) and Claude's tool calls (`%asked.about.window%`, RunCall) set `%askWindow%`.
   With a window other than the desktop → `window.ask`; else the desktop dialog, which stays up until answered
   (the display doesn't lower an `above` marked `keep`).
4. Tests: the sheet's answers (click, Enter, Esc, window closed), input blocked to the window while it's there,
   window.ask through the display; a goal test of Question with %askWindow%.
5. Ship: through the architect (C# on plang-os-stable), a new image (shell), the Windows runtime unchanged.
