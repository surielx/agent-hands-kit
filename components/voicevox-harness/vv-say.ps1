# vv-say.ps1 - VOICEVOX harness wrapper.
# Synthesizes Japanese speech through the VOICEVOX engine API (no GUI),
# prints the accent/pitch plan, and verifies the output WAV by measuring
# its F0 contour per accent phrase.
# Core: vv_harness.py (next to this script, or in $env:VV_HOME).
# Python: $env:VV_PYTHON, else <core dir>\.venv, else `python` on PATH
# (needs numpy + soundfile).
# Success marker (from the core): VV_OK <wav path> / VV_FAILED <reason>
param(
    [string]$Text,
    [string]$TextFile,
    [int]$Speaker = 10,          # VOICEVOX style id (10 = Amahare Hau, normal)
    [string]$Out,
    [double]$Speed = 1.0,
    [switch]$Rules               # opt-in gentle prosody edits (default OFF)
)
$ErrorActionPreference = 'Stop'
$coreDir = if ($env:VV_HOME) { $env:VV_HOME } else { $PSScriptRoot }
$core = Join-Path $coreDir 'vv_harness.py'
if (-not (Test-Path $core)) { Write-Output "VV_FAILED core not found: $core"; exit 1 }

$py = $null
if ($env:VV_PYTHON -and (Test-Path $env:VV_PYTHON)) { $py = $env:VV_PYTHON }
elseif (Test-Path (Join-Path $coreDir '.venv\Scripts\python.exe')) { $py = Join-Path $coreDir '.venv\Scripts\python.exe' }
else {
    $cmd = Get-Command python -ErrorAction SilentlyContinue
    if ($cmd) { $py = $cmd.Source }
}
if (-not $py) { Write-Output 'VV_FAILED no python found (set VV_PYTHON)'; exit 1 }

if (-not $Out) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $Out = Join-Path $coreDir "outputs\vv_$stamp.wav"
}
$argsList = @($core, '--speaker', $Speaker, '--out', $Out, '--speed', $Speed)
$tmpText = $null
if ($TextFile) {
    $argsList += @('--text-file', $TextFile)
} elseif ($Text) {
    $tmpText = Join-Path $env:TEMP ("vv_text_" + [guid]::NewGuid().ToString('N') + ".txt")
    [IO.File]::WriteAllText($tmpText, $Text, (New-Object Text.UTF8Encoding($false)))
    $argsList += @('--text-file', $tmpText)
} else {
    Write-Output 'VV_FAILED no -Text or -TextFile given'
    exit 1
}
if ($Rules) { $argsList += '--rules' }

& $py @argsList
$code = $LASTEXITCODE
if ($tmpText) { Remove-Item $tmpText -ErrorAction SilentlyContinue }
exit $code
