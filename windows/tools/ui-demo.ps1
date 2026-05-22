$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "ui.ps1")

Write-TuiHeader -Title "Interface Primitives" -Subtitle "Panels, image, art text, statuses, and charts." -ShowLogo

Write-TuiArtText -Text "tukevejtso"
Write-Host ""

Write-TuiPanel -Title "Design Direction" -Lines @(
    "PowerShell remains the native Windows scripting layer.",
    "ui.ps1 now owns reusable terminal rendering primitives.",
    "The resource image is rendered directly from resources\waajacamaya.png."
)

Write-Host ""
Write-TuiStatus -Label "Windows-native scripting" -State Good -Detail "PowerShell 5.1 baseline"
Write-TuiStatus -Label "Image renderer" -State Good -Detail "PNG to terminal half-block cells"
Write-TuiStatus -Label "Editor primitive" -State Info -Detail "Deferred; use external editor for now"
Write-TuiStatus -Label "Animation primitive" -State Info -Detail "Start with spinners and progress"

Write-Host ""
Write-TuiKeyValue -Key "CPU-style sparkline" -Value (Get-TuiSparkline -Values @(2, 4, 7, 5, 8, 12, 9, 11, 6, 13, 10, 15)) -ValueColor Cyan
Write-TuiKeyValue -Key "Training guard readiness" -Value (Get-TuiBar -Value 0.72 -Max 1 -Width 28) -ValueColor Green

Write-Host ""
Write-TuiPanel -Title "Borrowed From iinuji" -Lines @(
    "panel: boxed sections for diagnostics",
    "grid: structured layout helpers",
    "text_box: styled text and status emphasis",
    "buffer_box: future scrollable command logs",
    "plot: sparklines and compact braille charts",
    "image: terminal rendering for waajacamaya.png",
    "art_text: bitmap identity text for the brand"
)
