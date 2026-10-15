# v5 — Claude's system prompt (PAUSED 2026-10-15, Ingi: pause all bots)

Ingi's chat with PlangOS's Claude (desktop box) showed: a broken split ("PlangOS keeps it at ."), a frozen copy of the
instructions in the person's home, no map of where apps are, ListFiles dying on lost+found, no way to make a folder.

## Decided with Ingi
- Every agent is the same; only its root ("/") and context (window, title) differ. No root/sudo idea.
- The prompt is PlangOS's own, always current: rendered from /system/plangos/agent/instructions.md each time; the
  person's /agent/notes.md is added after it ("From the person").
- %!app.list% (decision 811): every app under /app/, current app first — core, architect schedules it. The prompt's
  apps line becomes that list then.
- Code Claude runs is always a goal, compiled: Run {goal} — the whole goal text in formal steps; PlangOS saves it
  (/agent/run/Run.goal), builds (formal needs no LLM: measured 0.8 s, no key), runs it in a plang of its own.
- Folder making: core gap (path.Mkdir isn't an action). Ingi: "maybe folder module with classes" → architect.

## Done (uncommitted before this pause, now committed as WIP, NOT in an image)
- agent/instructions.md rewritten (one prompt; where you are; what you can do; Run with a formal example).
- Screen.goal FirstWords: renders the system's instructions + /agent/notes.md (PersonsNotes); PlaceInstructions gone.
- agent/Run.goal (save, build, run; NotBuilt answers the build's output).
- Test kit now in /shared/os/tools/plangos/ (restore.sh, buildshell.sh, buildhost.sh, agenttest.sh, linhost/).

## Where it stopped (agenttest.sh with calls-run.json, Debug plang)
1. The desktop render still takes the app branch: "\"/\" is this window's app, :" — `{% if app %}` is true for the
   empty app the desktop sends. Find what %asked.about.app% is ("" vs null vs missing) and the template engine's
   truthiness; or pass app only when set.
2. Run hung: Claude "thinking" 39 s+, /Desktop/from-run.txt not written, no error. Check the debug log
   ($S/img/home/plang/.ct/err) for the Run goal: does terminal.start plang build wait (an ask? no PATH for plang?).
3. Then: lost+found removed at data-disk mount; build image; install; test on the harness first.

## Open with the architect on resume
folder module (name, actions, schedule), %!app.list%, the agent's one tool (Run).
