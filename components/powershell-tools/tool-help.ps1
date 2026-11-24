# tool-help.ps1 - print one tool's detailed documentation from tools\README.md.
# The resident layer is tools\INDEX.md (1 line per tool); use this for details
# only when you actually need them, instead of reading the whole README.
# Usage: powershell -File tools\tool-help.ps1 -Name <tool name, e.g. web-read>
# Final line: TOOL_HELP_OK name=<n> | TOOL_HELP_FAILED not found next: check INDEX.md for the exact tool name
param([Parameter(Mandatory = $true)][string]$Name)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$readme = "$env:AGENT_HOME\tools\README.md"
$lines = [IO.File]::ReadAllLines($readme, [Text.Encoding]::UTF8)
$key = $Name -replace '\.ps1$', ''
$start = -1
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^#{1,3}\s' -and $lines[$i] -match [regex]::Escape($key)) { $start = $i; break }
    if ($lines[$i] -match '^\s*[-*]\s+\*\*' -and $lines[$i] -match [regex]::Escape($key)) { $start = $i; break }
}
if ($start -lt 0) {
    # fallback: first plain mention
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match [regex]::Escape($key)) { $start = $i; break }
    }
}
if ($start -lt 0) { Write-Output ("TOOL_HELP_FAILED not found: " + $Name + " next: check INDEX.md for the exact tool name"); exit 1 }
$end = $lines.Count
for ($j = $start + 1; $j -lt $lines.Count; $j++) {
    if ($lines[$j] -match '^#{1,2}\s') { $end = $j; break }
    if (($j - $start) -ge 80) { $end = $j; break }
}
Write-Output ($lines[$start..($end - 1)] -join "`n")
Write-Output ("TOOL_HELP_OK name=" + $key)
