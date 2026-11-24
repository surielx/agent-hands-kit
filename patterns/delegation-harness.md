# Delegate Long Tasks to the Local LLM

## Fix the premises before starting

- Write the task premises into a task file before the delegate starts, covering the prompt verbatim, the one allowed write folder inside the delegate home, the exact output path, the deadline and the completion criteria.

- Treat that task file as the only source of premises and re-inject it verbatim after any context compression, so summaries carry progress only and never rewrite where output belongs or what was asked.

- Restrict writes physically to the allowed folder where the tooling allows it, instead of relying on the delegate to remember the location.

- Test each capability the plan depends on with a small measured check before starting, such as reading a test image or rendering a test page, and never treat a config declaration as proof that a capability reaches inference.

## Build in parts and keep a live report

- Create the scaffold before the delegate starts, with a parts folder, the final output location, a plan file that names the assemble command and a report file skeleton the delegate fills in as it works.

- Split any large output into parts under a per part size cap and assemble them with a tool that checks an end marker for the file type, instead of attempting one large write that a step limit can truncate mid file.

- Budget the run in stages, with a minimal working version placed in the final location early, then improvement, then a bounded number of verification loops, then a reserved report phase.

- Give the harness a report phase that survives truncation, by interrupting production before the deadline to finish the report and mechanically appending the file list and check results when the delegate does not.

## Verify with generic checks only

- Verify the finished artifact with generic checks that fit any task, such as file closure, syntax or error checks and opening or rendering the result in a working environment.

- Confirm the verification environment itself can run the artifact before blaming the artifact, and switch to a proven generic render route when the first route lacks a needed capability.

- Build only generic tools and measures, and never a tool or metric tailored to one task failure, one prompt word or one expected visual detail.

## Close and hand back

- End every delegated run with a closing report that names the artifact path, its size and closure check, the verification result and anything still unfinished, even when the run timed out.

- Report a run that produced no artifact or no report as a failed run with the reason, rather than letting it end silently.

- Judge the delegate output separately from any user judgement the task reserves, and label your evaluation as a work evaluation when the user keeps the final call.

## Available connectors

- [Tailscale](/opt/hatch/connectors/tailscale/CONNECTOR.md) for reaching the user's PC on their private network, where the local LLM and its harness tooling run.

- Use `muse.connector_search` to find other connectors and `muse.skill_search` to find related skills.

- If nothing here fits, look on the web for a maintained API or MCP server and set it up with [Custom Connectors and MCPs](/opt/muse/skills/custom-connector-setup/SKILL.md), or build a custom connector.

## Alternatives for better results

- Run a short drill with the same harness before a long or high stakes delegation, and fix harness faults the drill exposes while the cost is still minutes.

- Shorten the delegated task or split it into sequential smaller tasks when a drill shows the output cannot fit the step and time budget in one run.
