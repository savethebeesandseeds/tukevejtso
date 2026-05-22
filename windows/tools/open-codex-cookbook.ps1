$ErrorActionPreference = "Stop"

$path = "C:\Users\santi\OneDrive\Documents\codex_cookbook.html"

if (-not (Test-Path -LiteralPath $path)) {
    throw "Cookbook file was not found: $path"
}

try {
    Start-Process -FilePath $path
}
catch {
    throw "Could not open cookbook file: $path. Details: $($_.Exception.Message)"
}
