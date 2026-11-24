# blender-run.ps1 -- run a Python script in Blender background mode
param(
  [Parameter(Mandatory=$true)][string]$Script,
  [string]$Blend,
  [string]$LogFile,
  [string[]]$ExtraArgs
)
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

function Resolve-Blender {
  $dirs = Get-ChildItem 'C:\Program Files\Blender Foundation' -Directory -ErrorAction SilentlyContinue
  $cands = foreach ($d in $dirs) {
    if ($d.Name -match '(\d+)\.(\d+)') {
      $exe = Join-Path $d.FullName 'blender.exe'
      if (Test-Path $exe) {
        [PSCustomObject]@{ Ver = [version]("$($Matches[1]).$($Matches[2])"); Exe = $exe }
      }
    }
  }
  $best = $cands | Sort-Object Ver -Descending | Select-Object -First 1
  if ($best) { return $best.Exe }
  $cmd = Get-Command blender -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  return $null
}

$exe = Resolve-Blender
if (-not $exe) { Write-Output 'BLENDER_FAILED blender.exe not found'; exit 1 }
if (-not (Test-Path $Script)) { Write-Output "BLENDER_FAILED script not found: $Script"; exit 1 }
if ($Blend -and -not (Test-Path $Blend)) { Write-Output "BLENDER_FAILED blend file not found: $Blend"; exit 1 }

$scriptFull = (Resolve-Path $Script).Path
if (-not $LogFile) {
  $dir = [IO.Path]::GetDirectoryName($scriptFull)
  $base = [IO.Path]::GetFileNameWithoutExtension($scriptFull)
  $LogFile = Join-Path $dir "$base.blender.log"
}
$errFile = "$LogFile.err"

$argList = @('--background')
if ($Blend) { $argList += (Resolve-Path $Blend).Path }
$argList += @('--python', $scriptFull)
if ($ExtraArgs) { $argList += $ExtraArgs }
$argString = ($argList | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '

$p = Start-Process -FilePath $exe -ArgumentList $argString -Wait -PassThru -NoNewWindow `
      -RedirectStandardOutput $LogFile -RedirectStandardError $errFile
if (Test-Path $errFile) {
  if ((Get-Item $errFile).Length -gt 0) { Add-Content -Path $LogFile -Value (Get-Content $errFile) }
  Remove-Item $errFile -Force -ErrorAction SilentlyContinue
}
$logText = ''
if (Test-Path $LogFile) { $logText = Get-Content $LogFile -Raw -ErrorAction SilentlyContinue }
if ($logText) { Get-Content $LogFile -Tail 5 | ForEach-Object { Write-Output $_ } }

if ($p.ExitCode -ne 0) { Write-Output "BLENDER_FAILED exit=$($p.ExitCode) log=$LogFile"; exit 1 }
if ($logText -match 'Traceback \(most recent call last\)') { Write-Output "BLENDER_FAILED python traceback in log=$LogFile"; exit 1 }
Write-Output "BLENDER_OK $LogFile"
exit 0
