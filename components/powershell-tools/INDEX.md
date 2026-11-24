# Tool index — powershell-tools (1 line per tool)

Rule for every tool: the LAST line of output is the result marker (`*_OK` /
`*_FAILED <reason>`). Judge success by that line, not by the text above it.
If output may be long, pipe it through `cap-output.ps1`.

- cap-output.ps1 — run a command; if output exceeds a limit, save the full text to a file and print head + pointer only.
- delegate.ps1 — delegate a long task to a local LLM harness: fixed premises, prebuilt scaffold folder, enforced closing report (REPORT.md). See `patterns/delegation-harness.md`. (Written for the author's OpenCode + local inference setup; adapt the model/provider settings to your own.)
- everything-search.ps1 — pass-through to voidtools Everything `es.exe` for instant file search.
- job-start.ps1 / job-status.ps1 / job-tail.ps1 — detached background jobs via WMI, with status and log tail. Markers `JOB_*`.
- read-doc.ps1 — extract layout-preserved text (and optionally page images) from PDFs and documents.
- run-scheduled.ps1 — run a scheduled instruction file as a delegated task and log the result. (Author's harness example.)
- schedule-self.ps1 — register one-shot / repeating self-reminders as scheduled tasks.
- strata-lock.ps1 — file-based mutual exclusion for a single local inference server (named after the author's server, "Strata"; the pattern is generic — rename to taste).
- tool-help.ps1 — extract one tool's detailed help section on demand instead of reading a whole manual.
- web-read.ps1 — fetch a URL as readable text with offset paging and caching.

App batch wrappers (Blender / Inkscape / GIMP / FreeCAD / KiCad / LTspice) and
the image preview tool live in `../app-wrappers/`. The desktop GUI agent and
its thin client (`desktop.ps1`) live in `../desktop-agent/`.
