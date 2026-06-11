if ($null -eq $script:TuiImageRenderCache) {
    $script:TuiImageRenderCache = @{}
}

function Get-TuiWidth {
    try {
        $consoleWidth = [Console]::WindowWidth
    }
    catch {
        $consoleWidth = 80
    }

    if ($consoleWidth -lt 1) {
        $consoleWidth = 80
    }

    return [Math]::Max(56, [Math]::Min($consoleWidth - 1, 160))
}

function Get-TuiRoot {
    return (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..\..")).Path
}

function Get-TuiResourcePath {
    param([string] $Name)

    return (Join-Path (Join-Path (Get-TuiRoot) "resources") $Name)
}

function Test-TuiAnsi {
    if (-not [string]::IsNullOrWhiteSpace($env:NO_COLOR)) {
        return $false
    }

    return $true
}

function Get-TuiEsc {
    return [char]27
}

function Get-TuiAnsiForeground {
    param([System.Drawing.Color] $Color)

    $esc = Get-TuiEsc
    return "$esc[38;2;$($Color.R);$($Color.G);$($Color.B)m"
}

function Get-TuiAnsiBackground {
    param([System.Drawing.Color] $Color)

    $esc = Get-TuiEsc
    return "$esc[48;2;$($Color.R);$($Color.G);$($Color.B)m"
}

function Get-TuiAnsiReset {
    $esc = Get-TuiEsc
    return "$esc[0m"
}

function Write-TuiText {
    param(
        [string] $Text,
        [ConsoleColor] $ForegroundColor = [ConsoleColor]::Gray
    )

    Write-Host $Text -ForegroundColor $ForegroundColor
}

function Write-TuiRule {
    param(
        [ConsoleColor] $Color = [ConsoleColor]::DarkGray
    )

    $ruleWidth = [Math]::Min(25, (Get-TuiWidth))
    Write-Host ("=" * $ruleWidth) -ForegroundColor $Color
}

function Format-TuiFit {
    param(
        [string] $Text,
        [int] $Width
    )

    if ($Width -le 0) {
        return ""
    }

    if ($null -eq $Text) {
        $Text = ""
    }

    if ($Text.Length -le $Width) {
        return $Text
    }

    if ($Width -le 3) {
        return $Text.Substring(0, $Width)
    }

    return $Text.Substring(0, $Width - 3) + "..."
}

function ConvertFrom-TuiHexColor {
    param([string] $Hex)

    $token = $Hex.Trim()
    if ($token.StartsWith("#")) {
        $token = $token.Substring(1)
    }
    if ($token.Length -ne 6) {
        throw "Invalid RGB color: $Hex"
    }

    return [pscustomobject]@{
        R = [Convert]::ToInt32($token.Substring(0, 2), 16)
        G = [Convert]::ToInt32($token.Substring(2, 2), 16)
        B = [Convert]::ToInt32($token.Substring(4, 2), 16)
    }
}

function Format-TuiAnsiText {
    param(
        [string] $Text,
        [string] $Foreground = "",
        [string] $Background = "",
        [switch] $Bold
    )

    if (-not (Test-TuiAnsi)) {
        return $Text
    }

    $esc = Get-TuiEsc
    $prefix = ""
    if ($Bold) {
        $prefix += "$esc[1m"
    }
    if (-not [string]::IsNullOrWhiteSpace($Foreground)) {
        $fg = ConvertFrom-TuiHexColor -Hex $Foreground
        $prefix += "$esc[38;2;$($fg.R);$($fg.G);$($fg.B)m"
    }
    if (-not [string]::IsNullOrWhiteSpace($Background)) {
        $bg = ConvertFrom-TuiHexColor -Hex $Background
        $prefix += "$esc[48;2;$($bg.R);$($bg.G);$($bg.B)m"
    }

    return $prefix + $Text + (Get-TuiAnsiReset)
}

function Remove-TuiAnsi {
    param([string] $Text)

    if ($null -eq $Text) {
        return ""
    }

    $esc = [regex]::Escape((Get-TuiEsc).ToString())
    return [regex]::Replace($Text, "$esc\[[0-9;]*m", "")
}

function Get-TuiVisibleLength {
    param([string] $Text)

    return (Remove-TuiAnsi -Text $Text).Length
}

function Pad-TuiAnsiRight {
    param(
        [string] $Text,
        [int] $Width
    )

    $visible = Get-TuiVisibleLength -Text $Text
    if ($visible -ge $Width) {
        return $Text
    }

    return $Text + (" " * ($Width - $visible))
}

function Write-TuiImageCell {
    param(
        [System.Drawing.Color] $Top,
        [System.Drawing.Color] $Bottom,
        [int] $AlphaThreshold = 16
    )

    Write-Host (Get-TuiImageCell -Top $Top -Bottom $Bottom -AlphaThreshold $AlphaThreshold) -NoNewline
}

function Get-TuiImageCell {
    param(
        [System.Drawing.Color] $Top,
        [System.Drawing.Color] $Bottom,
        [int] $AlphaThreshold = 16
    )

    $upper = [char]0x2580
    $lower = [char]0x2584
    $space = " "

    $topVisible = $Top.A -ge $AlphaThreshold
    $bottomVisible = $Bottom.A -ge $AlphaThreshold

    if (-not $topVisible -and -not $bottomVisible) {
        return $space
    }

    if (-not (Test-TuiAnsi)) {
        if ($topVisible -and $bottomVisible) {
            return ([char]0x2588).ToString()
        }
        elseif ($topVisible) {
            return $upper.ToString()
        }
        else {
            return $lower.ToString()
        }
    }

    $reset = Get-TuiAnsiReset
    if ($topVisible -and $bottomVisible) {
        return ((Get-TuiAnsiForeground $Top) + (Get-TuiAnsiBackground $Bottom) + $upper + $reset)
    }
    elseif ($topVisible) {
        return ((Get-TuiAnsiForeground $Top) + $upper + $reset)
    }
    else {
        return ((Get-TuiAnsiForeground $Bottom) + $lower + $reset)
    }
}

function Get-TuiBitmapSample {
    param(
        [System.Drawing.Bitmap] $Bitmap,
        [double] $X,
        [double] $Y,
        [int] $SourceLeft = 0,
        [int] $SourceTop = 0
    )

    $sx = [Math]::Min($Bitmap.Width - 1, [Math]::Max(0, $SourceLeft + [int][Math]::Floor($X)))
    $sy = [Math]::Min($Bitmap.Height - 1, [Math]::Max(0, $SourceTop + [int][Math]::Floor($Y)))
    return $Bitmap.GetPixel($sx, $sy)
}

function Get-TuiBitmapContentBounds {
    param(
        [System.Drawing.Bitmap] $Bitmap,
        [int] $AlphaThreshold = 16,
        [int] $Padding = 12
    )

    $minX = $Bitmap.Width
    $minY = $Bitmap.Height
    $maxX = -1
    $maxY = -1

    for ($y = 0; $y -lt $Bitmap.Height; $y++) {
        for ($x = 0; $x -lt $Bitmap.Width; $x++) {
            if ($Bitmap.GetPixel($x, $y).A -ge $AlphaThreshold) {
                if ($x -lt $minX) { $minX = $x }
                if ($x -gt $maxX) { $maxX = $x }
                if ($y -lt $minY) { $minY = $y }
                if ($y -gt $maxY) { $maxY = $y }
            }
        }
    }

    if ($maxX -lt $minX -or $maxY -lt $minY) {
        return [pscustomobject]@{
            Left = 0
            Top = 0
            Width = $Bitmap.Width
            Height = $Bitmap.Height
        }
    }

    $left = [Math]::Max(0, $minX - $Padding)
    $top = [Math]::Max(0, $minY - $Padding)
    $right = [Math]::Min($Bitmap.Width - 1, $maxX + $Padding)
    $bottom = [Math]::Min($Bitmap.Height - 1, $maxY + $Padding)

    return [pscustomobject]@{
        Left = $left
        Top = $top
        Width = $right - $left + 1
        Height = $bottom - $top + 1
    }
}

function Write-TuiImage {
    param(
        [string] $Path,
        [int] $WidthCells = 22,
        [int] $MaxHeightRows = 11,
        [int] $AlphaThreshold = 16,
        [switch] $NoCenter
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }

    $render = New-TuiImageRender -Path $Path -WidthCells $WidthCells -MaxHeightRows $MaxHeightRows -AlphaThreshold $AlphaThreshold
    if ($null -eq $render) {
        return $false
    }

    $indent = ""
    if (-not $NoCenter) {
        $indentWidth = [Math]::Max(0, [int][Math]::Floor(((Get-TuiWidth) - $render.WidthCells) / 2.0))
        $indent = " " * $indentWidth
    }

    foreach ($line in $render.Lines) {
        Write-Host ($indent + $line)
    }

    return $true
}

function New-TuiImageRender {
    param(
        [string] $Path,
        [int] $WidthCells = 22,
        [int] $MaxHeightRows = 11,
        [int] $AlphaThreshold = 16
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $resolvedPath = (Resolve-Path -LiteralPath $Path).Path
    $file = Get-Item -LiteralPath $resolvedPath
    $cacheKey = "{0}|{1}|{2}|{3}|{4}" -f $resolvedPath, $file.LastWriteTimeUtc.Ticks, $WidthCells, $MaxHeightRows, $AlphaThreshold
    if ($script:TuiImageRenderCache.ContainsKey($cacheKey)) {
        return $script:TuiImageRenderCache[$cacheKey]
    }

    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        $bitmap = [System.Drawing.Bitmap]::FromFile($resolvedPath)
    }
    catch {
        Write-Host "Image renderer unavailable: $($_.Exception.Message)" -ForegroundColor Yellow
        return $false
    }

    try {
        if ($bitmap.Width -le 0 -or $bitmap.Height -le 0) {
            return $null
        }

        $bounds = Get-TuiBitmapContentBounds -Bitmap $bitmap -AlphaThreshold $AlphaThreshold
        $aspect = [double]$bounds.Height / [double]$bounds.Width
        $heightRows = [Math]::Max(1, [int][Math]::Ceiling(($WidthCells * $aspect) / 2.0))

        if ($heightRows -gt $MaxHeightRows) {
            $heightRows = [Math]::Max(1, $MaxHeightRows)
            $WidthCells = [Math]::Max(1, [int][Math]::Floor(($heightRows * 2.0) / $aspect))
        }

        $lines = New-Object System.Collections.Generic.List[string]
        $virtualRows = $heightRows * 2
        for ($row = 0; $row -lt $heightRows; $row++) {
            $builder = [System.Text.StringBuilder]::new()
            for ($col = 0; $col -lt $WidthCells; $col++) {
                $srcX = (($col + 0.5) / [double]$WidthCells) * $bounds.Width
                $srcTopY = ((($row * 2) + 0.5) / [double]$virtualRows) * $bounds.Height
                $srcBottomY = ((($row * 2) + 1.5) / [double]$virtualRows) * $bounds.Height
                $top = Get-TuiBitmapSample -Bitmap $bitmap -X $srcX -Y $srcTopY -SourceLeft $bounds.Left -SourceTop $bounds.Top
                $bottom = Get-TuiBitmapSample -Bitmap $bitmap -X $srcX -Y $srcBottomY -SourceLeft $bounds.Left -SourceTop $bounds.Top
                [void]$builder.Append((Get-TuiImageCell -Top $top -Bottom $bottom -AlphaThreshold $AlphaThreshold))
            }
            $lines.Add($builder.ToString())
        }

        $render = [pscustomobject]@{
            Lines = [string[]]$lines
            WidthCells = $WidthCells
            HeightRows = $heightRows
        }
        $script:TuiImageRenderCache[$cacheKey] = $render
        return $render
    }
    finally {
        $bitmap.Dispose()
    }
}

function Get-TuiGlyphRows {
    param([char] $Char)

    switch ($Char.ToString().ToUpperInvariant()) {
        "A" { return @("01110", "10001", "10001", "11111", "10001", "10001", "10001") }
        "D" { return @("11110", "10001", "10001", "10001", "10001", "10001", "11110") }
        "E" { return @("11111", "10000", "10000", "11110", "10000", "10000", "11111") }
        "I" { return @("111", "010", "010", "010", "010", "010", "111") }
        "J" { return @("00111", "00010", "00010", "00010", "10010", "10010", "01100") }
        "K" { return @("10001", "10010", "10100", "11000", "10100", "10010", "10001") }
        "N" { return @("10001", "11001", "10101", "10011", "10001", "10001", "10001") }
        "O" { return @("01110", "10001", "10001", "10001", "10001", "10001", "01110") }
        "S" { return @("01111", "10000", "10000", "01110", "00001", "00001", "11110") }
        "T" { return @("11111", "00100", "00100", "00100", "00100", "00100", "00100") }
        "U" { return @("10001", "10001", "10001", "10001", "10001", "10001", "01110") }
        "V" { return @("10001", "10001", "10001", "10001", "10001", "01010", "00100") }
        "W" { return @("10001", "10001", "10001", "10101", "10101", "10101", "01010") }
        " " { return @("000", "000", "000", "000", "000", "000", "000") }
        default { return @("11111", "00001", "00010", "00100", "00100", "00000", "00100") }
    }
}

function Write-TuiArtText {
    param(
        [string] $Text,
        [ConsoleColor[]] $Palette = @([ConsoleColor]::Cyan, [ConsoleColor]::Green, [ConsoleColor]::Yellow)
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return
    }

    $glyphs = @()
    foreach ($char in $Text.ToCharArray()) {
        $glyphs += ,(Get-TuiGlyphRows -Char $char)
    }

    $block = [char]0x2588
    for ($row = 0; $row -lt 7; $row++) {
        for ($glyphIndex = 0; $glyphIndex -lt $glyphs.Count; $glyphIndex++) {
            $glyphRow = $glyphs[$glyphIndex][$row]
            $color = $Palette[$glyphIndex % $Palette.Count]
            for ($col = 0; $col -lt $glyphRow.Length; $col++) {
                if ($glyphRow[$col] -eq "1") {
                    Write-Host $block -NoNewline -ForegroundColor $color
                }
                else {
                    Write-Host " " -NoNewline
                }
            }
            Write-Host " " -NoNewline
        }
        Write-Host ""
    }
}

function Write-TuiHeader {
    param(
        [string] $Title,
        [string] $Subtitle = "",
        [switch] $ShowLogo
    )

    Clear-Host
    if ($ShowLogo) {
        $logoPath = Get-TuiResourcePath -Name "waajacamaya.png"
        $logo = New-TuiImageRender -Path $logoPath -WidthCells 34 -MaxHeightRows 18
        if ($null -ne $logo) {
            $width = Get-TuiWidth
            $gap = 4
            $leftWidth = [Math]::Max(32, $width - $logo.WidthCells - $gap)
            if ($leftWidth -lt 36) {
                [void](Write-TuiImage -Path $logoPath -WidthCells 28 -MaxHeightRows 15)
                Write-Host ""
            }
            else {
                $leftLines = @(
                    ("tukevejtso / " + $Title),
                    $Subtitle,
                    "",
                    "tk demo  |  tk reboot status"
                )
                $rowCount = [Math]::Max($leftLines.Count, $logo.Lines.Count)
                for ($row = 0; $row -lt $rowCount; $row++) {
                    $left = if ($row -lt $leftLines.Count) { $leftLines[$row] } else { "" }
                    $left = Format-TuiFit -Text $left -Width $leftWidth
                    $right = if ($row -lt $logo.Lines.Count) { $logo.Lines[$row] } else { "" }
                    if ($row -eq 0) {
                        Write-Host ($left.PadRight($leftWidth) + (" " * $gap)) -NoNewline -ForegroundColor Cyan
                    }
                    elseif ($row -eq 1 -or $row -eq 3) {
                        Write-Host ($left.PadRight($leftWidth) + (" " * $gap)) -NoNewline -ForegroundColor DarkGray
                    }
                    else {
                        Write-Host ($left.PadRight($leftWidth) + (" " * $gap)) -NoNewline -ForegroundColor White
                    }
                    Write-Host $right
                }
                Write-Host ""
            }
            return
        }
    }

    Write-TuiRule -Color DarkCyan
    Write-Host " tukevejtso" -NoNewline -ForegroundColor Cyan
    Write-Host (" / " + $Title) -ForegroundColor White
    if (-not [string]::IsNullOrWhiteSpace($Subtitle)) {
        Write-Host (" " + $Subtitle) -ForegroundColor DarkGray
    }
    Write-TuiRule -Color DarkCyan
    Write-Host ""
}

function Write-TuiBadge {
    param(
        [string] $Text,
        [ConsoleColor] $ForegroundColor = [ConsoleColor]::Black,
        [ConsoleColor] $BackgroundColor = [ConsoleColor]::Gray
    )

    Write-Host (" {0} " -f $Text) -NoNewline -ForegroundColor $ForegroundColor -BackgroundColor $BackgroundColor
}

function Write-TuiKeyValue {
    param(
        [string] $Key,
        [string] $Value,
        [ConsoleColor] $ValueColor = [ConsoleColor]::Gray
    )

    Write-Host ("{0,-34} " -f $Key) -NoNewline -ForegroundColor DarkGray
    Write-Host $Value -ForegroundColor $ValueColor
}

function Write-TuiStatus {
    param(
        [string] $Label,
        [ValidateSet("Good", "Warn", "Bad", "Info")]
        [string] $State,
        [string] $Detail = ""
    )

    $color = switch ($State) {
        "Good" { [ConsoleColor]::Green }
        "Warn" { [ConsoleColor]::Yellow }
        "Bad" { [ConsoleColor]::Red }
        default { [ConsoleColor]::Cyan }
    }

    Write-Host ("{0,-34} " -f $Label) -NoNewline -ForegroundColor DarkGray
    Write-TuiBadge -Text $State.ToUpperInvariant() -ForegroundColor Black -BackgroundColor $color
    if (-not [string]::IsNullOrWhiteSpace($Detail)) {
        Write-Host (" " + $Detail) -ForegroundColor $color
    }
    else {
        Write-Host ""
    }
}

function Get-TuiBar {
    param(
        [double] $Value,
        [double] $Max = 1.0,
        [int] $Width = 24
    )

    if ($Max -le 0) {
        $Max = 1.0
    }

    $ratio = [Math]::Max(0.0, [Math]::Min(1.0, $Value / $Max))
    $filled = [int][Math]::Round($ratio * $Width)
    $block = [char]0x2588
    $light = [char]0x2591
    return (($block.ToString() * $filled) + ($light.ToString() * ($Width - $filled)))
}

function Get-TuiSparkline {
    param([double[]] $Values)

    if ($null -eq $Values -or $Values.Count -eq 0) {
        return ""
    }

    $glyphs = @(
        [char]0x2581,
        [char]0x2582,
        [char]0x2583,
        [char]0x2584,
        [char]0x2585,
        [char]0x2586,
        [char]0x2587,
        [char]0x2588
    )
    $min = ($Values | Measure-Object -Minimum).Minimum
    $max = ($Values | Measure-Object -Maximum).Maximum
    $span = $max - $min
    if ($span -le 0) {
        return (($glyphs[0].ToString()) * $Values.Count)
    }

    $out = ""
    foreach ($value in $Values) {
        $index = [int][Math]::Floor((($value - $min) / $span) * ($glyphs.Count - 1))
        $index = [Math]::Max(0, [Math]::Min($glyphs.Count - 1, $index))
        $out += $glyphs[$index]
    }
    return $out
}

function Write-TuiPanel {
    param(
        [string] $Title,
        [string[]] $Lines,
        [int] $Width = 0,
        [ConsoleColor] $BorderColor = [ConsoleColor]::DarkCyan
    )

    if ($Width -le 0) {
        $Width = Get-TuiWidth
    }

    $Width = [Math]::Max(24, $Width)
    $innerWidth = $Width - 4
    $tl = [char]0x250C
    $tr = [char]0x2510
    $bl = [char]0x2514
    $br = [char]0x2518
    $h = [char]0x2500
    $v = [char]0x2502

    $titleText = if ([string]::IsNullOrWhiteSpace($Title)) { "" } else { " $Title " }
    $topFill = [Math]::Max(0, $Width - 2 - $titleText.Length)
    Write-Host ($tl + $titleText + ($h.ToString() * $topFill) + $tr) -ForegroundColor $BorderColor

    foreach ($line in $Lines) {
        $text = if ($null -eq $line) { "" } else { $line }
        while ($text.Length -gt $innerWidth) {
            $chunk = $text.Substring(0, $innerWidth)
            Write-Host ($v + " " + $chunk + " " + $v) -ForegroundColor Gray
            $text = $text.Substring($innerWidth)
        }
        Write-Host ($v + " " + $text.PadRight($innerWidth) + " " + $v) -ForegroundColor Gray
    }

    Write-Host ($bl + ($h.ToString() * ($Width - 2)) + $br) -ForegroundColor $BorderColor
}

function Write-TuiHelp {
    Write-Host ""
    Write-Host (Get-TuiHelpLine)
}

function Get-TuiHeaderLines {
    param(
        [string] $Title,
        [string] $Subtitle = ""
    )

    $rule = "=" * [Math]::Min(25, (Get-TuiWidth))
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add((Format-TuiAnsiText -Text $rule -Foreground "#008b8b"))
    $lines.Add(
        (Format-TuiAnsiText -Text " tukevejtso" -Foreground "#5dd9e8" -Bold) +
        (Format-TuiAnsiText -Text (" / " + $Title) -Foreground "#f8fbff")
    )

    if (-not [string]::IsNullOrWhiteSpace($Subtitle)) {
        $lines.Add((Format-TuiAnsiText -Text (" " + $Subtitle) -Foreground "#777777"))
    }

    $lines.Add((Format-TuiAnsiText -Text $rule -Foreground "#008b8b"))
    $lines.Add("")
    return [string[]]$lines
}

function Get-TuiHelpLine {
    return (
        " " +
        (Format-TuiAnsiText -Text "Up/Down" -Foreground "#5dd9e8" -Bold) +
        (Format-TuiAnsiText -Text " move   " -Foreground "#777777") +
        (Format-TuiAnsiText -Text "Enter" -Foreground "#5dd9e8" -Bold) +
        (Format-TuiAnsiText -Text " run   " -Foreground "#777777") +
        (Format-TuiAnsiText -Text "Digits" -Foreground "#5dd9e8" -Bold) +
        (Format-TuiAnsiText -Text " jump   " -Foreground "#777777") +
        (Format-TuiAnsiText -Text "Home/End" -Foreground "#5dd9e8" -Bold) +
        (Format-TuiAnsiText -Text " edge   " -Foreground "#777777") +
        (Format-TuiAnsiText -Text "Q/Esc" -Foreground "#5dd9e8" -Bold) +
        (Format-TuiAnsiText -Text " quit" -Foreground "#777777")
    )
}

function Write-TuiFrame {
    param(
        [string[]] $Lines,
        [switch] $Initial
    )

    if (Test-TuiAnsi -and -not [Console]::IsOutputRedirected) {
        $esc = Get-TuiEsc
        $prefix = if ($Initial) { "$esc[?25l$esc[2J$esc[H" } else { "$esc[H" }
        [Console]::Write($prefix + ($Lines -join "`r`n") + "$esc[J")
        return
    }

    Clear-Host
    foreach ($line in $Lines) {
        [Console]::WriteLine((Remove-TuiAnsi -Text $line))
    }
}

function Show-TuiCursor {
    if (Test-TuiAnsi -and -not [Console]::IsOutputRedirected) {
        $esc = Get-TuiEsc
        [Console]::Write("$esc[?25h")
    }
}

function Select-TuiItem {
    param(
        [string] $Title,
        [string] $Subtitle = "",
        [array] $Items,
        [scriptblock] $FormatItem,
        [scriptblock] $RenderItem,
        [scriptblock] $FormatStyledItem,
        [switch] $ShowLogo
    )

    if ($Items.Count -eq 0) {
        return $null
    }

    $selected = 0
    $renderedOnce = $false
    $numberBuffer = ""

    try {
        while ($true) {
            if ($ShowLogo -and $null -ne $FormatStyledItem) {
                $frameLines = New-Object System.Collections.Generic.List[string]
                foreach ($line in (Get-TuiHeaderLines -Title $Title -Subtitle $Subtitle)) {
                    $frameLines.Add($line)
                }

                $logoPath = Get-TuiResourcePath -Name "waajacamaya.png"
                $logo = New-TuiImageRender -Path $logoPath -WidthCells 34 -MaxHeightRows 18
                $gap = 5
                $totalWidth = Get-TuiWidth
                $leftWidth = [Math]::Min(72, [Math]::Max(48, $totalWidth - $gap - $(if ($null -eq $logo) { 0 } else { $logo.WidthCells })))

                $leftLines = New-Object System.Collections.Generic.List[string]
                for ($i = 0; $i -lt $Items.Count; $i++) {
                    $number = "$($i + 1)."
                    $leftLines.Add((& $FormatStyledItem $Items[$i] $i ($i -eq $selected) $number))
                }

                $rightLines = if ($null -eq $logo) { @() } else { $logo.Lines }
                $rowCount = [Math]::Max($leftLines.Count, $rightLines.Count)

                for ($row = 0; $row -lt $rowCount; $row++) {
                    $left = if ($row -lt $leftLines.Count) { $leftLines[$row] } else { "" }
                    $right = if ($row -lt $rightLines.Count) { $rightLines[$row] } else { "" }
                    $line = Pad-TuiAnsiRight -Text $left -Width $leftWidth
                    if (-not [string]::IsNullOrEmpty($right)) {
                        $line += (" " * $gap) + $right
                    }
                    $frameLines.Add($line)
                }

                $frameLines.Add("")
                $frameLines.Add((Get-TuiHelpLine))
                Write-TuiFrame -Lines ([string[]]$frameLines) -Initial:(-not $renderedOnce)
                $renderedOnce = $true
            }
            elseif ($null -eq $RenderItem) {
                $frameLines = New-Object System.Collections.Generic.List[string]
                foreach ($line in (Get-TuiHeaderLines -Title $Title -Subtitle $Subtitle)) {
                    $frameLines.Add($line)
                }

                for ($i = 0; $i -lt $Items.Count; $i++) {
                    $number = "$($i + 1)."
                    $isSelected = $i -eq $selected
                    $text = & $FormatItem $Items[$i]

                    if ($isSelected) {
                        $frameLines.Add((Format-TuiAnsiText -Text ("  {0,-3} {1}" -f $number, $text).PadRight(52) -Foreground "#000000" -Background "#5dd9e8"))
                    }
                    else {
                        $frameLines.Add(
                            (Format-TuiAnsiText -Text ("  {0,-3} " -f $number) -Foreground "#777777") +
                            $text
                        )
                    }
                }

                $frameLines.Add("")
                $frameLines.Add((Get-TuiHelpLine))
                Write-TuiFrame -Lines ([string[]]$frameLines) -Initial:(-not $renderedOnce)
                $renderedOnce = $true
            }
            else {
                Write-TuiHeader -Title $Title -Subtitle $Subtitle -ShowLogo:$ShowLogo

                for ($i = 0; $i -lt $Items.Count; $i++) {
                    $number = "$($i + 1)."
                    $isSelected = $i -eq $selected
                    & $RenderItem $Items[$i] $i $isSelected $number
                }

                Write-TuiHelp
            }

            if ([Console]::IsInputRedirected) {
                return $null
            }

            try {
                $key = [Console]::ReadKey($true)
            }
            catch {
                return $null
            }

            switch ($key.Key) {
                "UpArrow" {
                    $numberBuffer = ""
                    $selected--
                    if ($selected -lt 0) { $selected = $Items.Count - 1 }
                }
                "DownArrow" {
                    $numberBuffer = ""
                    $selected++
                    if ($selected -ge $Items.Count) { $selected = 0 }
                }
                "Home" {
                    $numberBuffer = ""
                    $selected = 0
                }
                "End" {
                    $numberBuffer = ""
                    $selected = $Items.Count - 1
                }
                "Enter" {
                    return $Items[$selected]
                }
                "Escape" {
                    return $null
                }
                "Q" {
                    return $null
                }
                default {
                    if ($key.KeyChar -match "^[0-9]$") {
                        $digit = $key.KeyChar.ToString()
                        if ($digit -eq "0" -and [string]::IsNullOrEmpty($numberBuffer)) {
                            continue
                        }

                        $candidateText = $numberBuffer + $digit
                        $candidate = 0
                        $maxDigits = $Items.Count.ToString().Length
                        if ([int]::TryParse($candidateText, [ref] $candidate) -and
                            $candidate -ge 1 -and
                            $candidate -le $Items.Count) {
                            $selected = $candidate - 1
                            if ($Items.Count -lt 10 -or
                                $candidateText.Length -ge $maxDigits -or
                                (($candidate * 10) -gt $Items.Count)) {
                                $numberBuffer = ""
                            }
                            else {
                                $numberBuffer = $candidateText
                            }
                        }
                        else {
                            $numberBuffer = ""
                        }
                    }
                    else {
                        $numberBuffer = ""
                    }
                }
            }
        }
    }
    finally {
        Show-TuiCursor
    }
}
