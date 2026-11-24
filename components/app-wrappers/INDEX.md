# Tool index — app-wrappers (1 line per tool)

Each wrapper runs the real application headlessly with a script or CLI
arguments, waits for completion, and judges success by declared outputs —
not by exit code alone. The LAST line of output is the result marker
(`*_OK` / `*_FAILED <reason>`).

- blender-run.ps1 — run a Python script in Blender's background mode (`bpy` full access). Resolves Blender under Program Files or PATH.
- inkscape-run.ps1 — pass arguments straight to Inkscape's CLI (SVG import/export, batch conversion). No param() block on purpose (see header note).
- gimp-run.ps1 — run Script-Fu or Python-Fu batch expressions in GIMP; success judged from the batch log, not the process exit.
- freecad-run.ps1 — run a Python script in FreeCAD's own environment (FreeCAD/Part/Mesh); success judged by `-ExpectFile` outputs created or updated in the run.
- kicad-run.ps1 — pass-through to `kicad-cli` (DRC/ERC, Gerber/PDF export, etc.).
- ltspice-run.ps1 — run an LTspice netlist simulation in batch mode with timeout handling.
- img-peek.ps1 — make a small preview of an image (shrink / crop / contact sheet) so an agent can check it visually without loading the full image into context.

Requirements: the corresponding application installed on Windows.
Executable resolution is generic (Program Files / `%LOCALAPPDATA%\Programs` / PATH).
