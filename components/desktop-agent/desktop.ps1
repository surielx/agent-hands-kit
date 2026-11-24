# desktop.ps1 - client for the resident desktop-agent (GUI control of the user's PC desktop).
# All arguments are passed through to desktop-agent.exe; the result is printed as JSON.
# Usage: powershell -ExecutionPolicy Bypass -File tools\desktop.ps1 <command> [args...]
# Run with no arguments (or 'help') to list commands.
# Prefix with -DryRun to print the command without executing it.
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest
)
[Console]::OutputEncoding = [Text.Encoding]::UTF8
if ($Rest -and $Rest[0] -eq '-DryRun') {
    $cmd = @()
    if ($Rest.Count -gt 1) { $cmd = $Rest[1..($Rest.Count - 1)] }
    Write-Output ("DRYRUN desktop-agent.exe " + ($cmd -join ' '))
    exit 0
}
$exe = Join-Path $env:USERPROFILE 'tools\desktop-agent\desktop-agent.exe'
if (-not (Test-Path $exe)) {
    Write-Output '{"ok":false,"error":"desktop-agent.exe not found"}'
    exit 1
}
& $exe @Rest
exit $LASTEXITCODE
