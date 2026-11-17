param([switch] $PrintPath)
$ErrorActionPreference = 'Stop'
$page = Join-Path $PSScriptRoot 'audio-test.html'
if (-not (Test-Path -LiteralPath $page -PathType Leaf)) { throw "Audio lab page is missing: $page" }
if ($PrintPath) { Write-Output $page; return }
# OS integration only: analysis and capture run locally in the browser.
Start-Process -FilePath $page
