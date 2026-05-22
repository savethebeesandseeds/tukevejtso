$ErrorActionPreference = "Stop"

$esc = [char]27

Write-Host "ANSI color/background test"
Write-Host ""
Write-Host "If the terminal supports background colors, each label below should appear on a colored block."
Write-Host ""

$basic = @(
    @{ Name = "black"; Code = 40 },
    @{ Name = "red"; Code = 41 },
    @{ Name = "green"; Code = 42 },
    @{ Name = "yellow"; Code = 43 },
    @{ Name = "blue"; Code = 44 },
    @{ Name = "magenta"; Code = 45 },
    @{ Name = "cyan"; Code = 46 },
    @{ Name = "white"; Code = 47 }
)

Write-Host "Basic ANSI backgrounds:"
foreach ($color in $basic) {
    Write-Host "$esc[30;$($color.Code)m  $($color.Name.PadRight(8))  $esc[0m"
}

Write-Host ""
Write-Host "Bright ANSI backgrounds:"
foreach ($color in $basic) {
    $brightCode = $color.Code + 60
    Write-Host "$esc[30;$($brightCode)m  bright $($color.Name.PadRight(8))  $esc[0m"
}

Write-Host ""
Write-Host "24-bit truecolor backgrounds:"
Write-Host "$esc[38;2;255;255;255;48;2;20;90;160m  blue truecolor background  $esc[0m"
Write-Host "$esc[38;2;20;20;20;48;2;230;180;60m  gold truecolor background  $esc[0m"
Write-Host "$esc[38;2;255;255;255;48;2;120;40;140m  purple truecolor background  $esc[0m"

Write-Host ""
Write-Host "Environment hints:"
foreach ($name in @("WT_SESSION", "TERM", "COLORTERM", "NO_COLOR", "FORCE_COLOR")) {
    $value = [Environment]::GetEnvironmentVariable($name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        $value = "<unset>"
    }
    Write-Host ("  {0,-13} {1}" -f $name, $value)
}
