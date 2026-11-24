# cap-output.ps1 - cap a command's output before it enters the context.
# Pipe any command through this: if the total output exceeds -MaxChars, the full
# text is saved to a file and only the head plus a pointer line is printed.
# Usage: <command> | powershell -File tools\cap-output.ps1 [-MaxChars 4000] [-Name label]
# Final line: OUTPUT_OK chars=<n> | OUTPUT_CAPPED total=<n> saved=<path>
param([int]$MaxChars = 4000, [string]$Name = 'output')
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$lines = @($input)
$text = ($lines -join "`n")
if ($text.Length -le $MaxChars) {
    Write-Output $text
    Write-Output ("OUTPUT_OK chars=" + $text.Length)
    exit 0
}
$dir = "$env:AGENT_HOME\out-overflow"
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$safe = ($Name -replace '[^a-zA-Z0-9\-]', '-')
$path = Join-Path $dir ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + $safe + '.txt')
[IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
Write-Output $text.Substring(0, $MaxChars)
Write-Output ("OUTPUT_CAPPED total=" + $text.Length + " saved=" + $path)
