# inkscape-run.ps1 -- thin passthrough wrapper for the Inkscape CLI
# NOTE: no param() block on purpose. Inkscape args such as -w collide with
# PowerShell common-parameter prefixes (-WarningAction etc.) and fail binding;
# taking $args verbatim passes everything through untouched.
$InkscapeArgs = @($args)
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

function Resolve-Inkscape {
  $known = 'C:\Program Files\Inkscape\bin\inkscape.com'
  if (Test-Path $known) { return $known }
  $hits = Get-ChildItem 'C:\Program Files\Inkscape' -Recurse -Filter 'inkscape.com' -ErrorAction SilentlyContinue |
    Select-Object -First 1
  if ($hits) { return $hits.FullName }
  $cmd = Get-Command inkscape -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  return $null
}

$exe = Resolve-Inkscape
if (-not $exe) { Write-Output 'INKSCAPE_FAILED inkscape.com not found'; exit 1 }
if (-not $InkscapeArgs -or $InkscapeArgs.Count -eq 0) {
  Write-Output 'INKSCAPE_FAILED no arguments (pass Inkscape CLI arguments as-is)'
  exit 1
}
& $exe @InkscapeArgs
$code = $LASTEXITCODE
if ($code -ne 0) { Write-Output "INKSCAPE_FAILED exit=$code"; exit 1 }
Write-Output 'INKSCAPE_OK'
exit 0
