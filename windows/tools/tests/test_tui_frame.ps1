# Run with Windows PowerShell 5.1; no Pester dependency is required.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\ui.ps1')
$script:Passed = 0
$script:Failures = New-Object 'System.Collections.Generic.List[string]'

function Assert-True([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}
function Test-Case([string] $Name, [scriptblock] $Body) {
    try { & $Body; $script:Passed++; Write-Host "PASS $Name" }
    catch { $script:Failures.Add("$Name : $($_.Exception.Message)"); Write-Host "FAIL $Name : $($_.Exception.Message)`n$($_.ScriptStackTrace)" }
}

# Model the actual VT output, including the background used by erase operations.
# Checking only the input strings misses stale cells left from the previous frame.
function New-TestTerminal {
    $terminal = [pscustomobject]@{
        Width = 60; Height = 12; X = 0; Y = 0; Background = 'default'
        Text = (New-Object 'string[,]' 12, 60)
        Colors = (New-Object 'string[,]' 12, 60)
        Erases = (New-Object 'System.Collections.Generic.List[string]')
    }
    for ($y = 0; $y -lt $terminal.Height; $y++) {
        for ($x = 0; $x -lt $terminal.Width; $x++) {
            $terminal.Text[$y, $x] = ' '
            $terminal.Colors[$y, $x] = 'default'
        }
    }
    return $terminal
}
function Clear-TestCells($Terminal, [int] $Start, [int] $End) {
    $Terminal.Erases.Add($Terminal.Background)
    for ($cell = $Start; $cell -lt $End; $cell++) {
        $y = [int][Math]::Floor($cell / $Terminal.Width)
        $x = $cell % $Terminal.Width
        $Terminal.Text[$y, $x] = ' '
        $Terminal.Colors[$y, $x] = $Terminal.Background
    }
}
function Write-TestSequence($Terminal, [string] $Sequence) {
    $esc = [char]27
    for ($index = 0; $index -lt $Sequence.Length; $index++) {
        $char = $Sequence[$index]
        if ($char -eq $esc) {
            $match = [regex]::Match($Sequence.Substring($index), '^\x1b\[([0-9;?]*)([A-Za-z])')
            Assert-True $match.Success 'Unrecognized VT escape'
            $arguments = $match.Groups[1].Value
            switch -CaseSensitive ($match.Groups[2].Value) {
                'H' { Assert-True ($arguments -eq '') 'Unexpected cursor coordinates'; $Terminal.X = 0; $Terminal.Y = 0 }
                'K' {
                    Assert-True ($arguments -eq '2') 'Expected whole-line erase'
                    Clear-TestCells $Terminal ($Terminal.Y * $Terminal.Width) (($Terminal.Y + 1) * $Terminal.Width)
                }
                'J' {
                    Assert-True ($arguments -in @('', '2')) 'Unexpected screen erase mode'
                    $start = if ($arguments -eq '2') { 0 } else { $Terminal.Y * $Terminal.Width + $Terminal.X }
                    Clear-TestCells $Terminal $start ($Terminal.Height * $Terminal.Width)
                }
                'm' {
                    $codes = $arguments -split ';'
                    for ($code = 0; $code -lt $codes.Count; $code++) {
                        switch ($codes[$code]) {
                            '0' { $Terminal.Background = 'default' }
                            '1' { }
                            '38' { Assert-True ($codes[$code + 1] -eq '2') 'Expected RGB foreground'; $code += 4 }
                            '48' {
                                Assert-True ($codes[$code + 1] -eq '2') 'Expected RGB background'
                                $Terminal.Background = $codes[($code + 2)..($code + 4)] -join ','
                                $code += 4
                            }
                            default { throw "Unexpected SGR parameter $($codes[$code])" }
                        }
                    }
                }
                'l' { Assert-True ($arguments -eq '?25') 'Unexpected mode change' }
                default { throw "Unexpected VT command $($match.Value)" }
            }
            $index += $match.Length - 1
        }
        elseif ($char -eq "`r") { $Terminal.X = 0 }
        elseif ($char -eq "`n") { $Terminal.Y++ }
        else {
            Assert-True ($Terminal.X -lt $Terminal.Width -and $Terminal.Y -lt $Terminal.Height) 'Fixture exceeds terminal bounds'
            $Terminal.Text[$Terminal.Y, $Terminal.X] = $char.ToString()
            $Terminal.Colors[$Terminal.Y, $Terminal.X] = $Terminal.Background
            $Terminal.X++
        }
    }
}
function Assert-TestRow($Terminal, [int] $Row, [string] $Text, [string] $Background = 'default') {
    for ($x = 0; $x -lt $Terminal.Width; $x++) {
        $expectedChar = if ($x -lt $Text.Length) { $Text[$x].ToString() } else { ' ' }
        $expectedColor = if ($x -lt $Text.Length) { $Background } else { 'default' }
        Assert-True ($Terminal.Text[$Row, $x] -ceq $expectedChar) "Unexpected character at row $Row, column $x"
        Assert-True ($Terminal.Colors[$Row, $x] -ceq $expectedColor) "Stale background at row $Row, column $x"
    }
}

$originalColor = $env:NO_COLOR
$env:NO_COLOR = ''
try {
    Test-Case 'PowerShell 5.1 runtime' {
        Assert-True ($PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -eq 1) 'Run this test with powershell.exe, not pwsh.'
    }
    Test-Case 'Moving selection clears old colored padding and shorter labels' {
        $terminal = New-TestTerminal
        $first = (Format-TuiAnsiText -Text 'A long folder name'.PadRight(50) -Background '#226b94')
        Write-TestSequence $terminal (Get-TuiFrameSequence -Lines @($first, 'Second folder') -Initial)
        $second = (Format-TuiAnsiText -Text 'Second folder'.PadRight(50) -Background '#226b94')
        Write-TestSequence $terminal (Get-TuiFrameSequence -Lines @('A long folder name', $second))
        Assert-TestRow $terminal 0 'A long folder name'
        Assert-TestRow $terminal 1 'Second folder'.PadRight(50) '34,107,148'
        Write-TestSequence $terminal (Get-TuiFrameSequence -Lines @('Short', $second))
        Assert-TestRow $terminal 0 'Short'
        Assert-TestRow $terminal 1 'Second folder'.PadRight(50) '34,107,148'
    }
    Test-Case 'Blank rows erase previous text and selection backgrounds' {
        $terminal = New-TestTerminal
        $selected = Format-TuiAnsiText -Text 'Selected'.PadRight(50) -Background '#226b94'
        Write-TestSequence $terminal (Get-TuiFrameSequence -Lines @('Header', $selected, 'Footer') -Initial)
        Write-TestSequence $terminal (Get-TuiFrameSequence -Lines @('Header', '', 'Footer'))
        Assert-TestRow $terminal 1 ''
        Assert-TestRow $terminal 2 'Footer'
    }
    Test-Case 'Shorter and empty frames remove rows from the previous frame' {
        $terminal = New-TestTerminal
        $selected = Format-TuiAnsiText -Text 'Selected'.PadRight(50) -Background '#226b94'
        Write-TestSequence $terminal (Get-TuiFrameSequence -Lines @('Old header', $selected, 'Old footer', 'Old help') -Initial)
        Write-TestSequence $terminal (Get-TuiFrameSequence -Lines @('New'))
        Assert-TestRow $terminal 0 'New'
        for ($row = 1; $row -lt $terminal.Height; $row++) { Assert-TestRow $terminal $row '' }
        Write-TestSequence $terminal (Get-TuiFrameSequence -Lines @())
        for ($row = 0; $row -lt $terminal.Height; $row++) { Assert-TestRow $terminal $row '' }
    }
    Test-Case 'Every erase uses the default background even after unclosed styles' {
        $terminal = New-TestTerminal
        $terminal.Background = 'inherited background'
        $unclosedStyle = ([char]27).ToString() + '[48;2;34;107;148mSelected'
        Write-TestSequence $terminal (Get-TuiFrameSequence -Lines @($unclosedStyle, 'Plain') -Initial)
        Assert-TestRow $terminal 0 'Selected' '34,107,148'
        Assert-TestRow $terminal 1 'Plain'
        $terminal.Background = 'inherited background'
        Write-TestSequence $terminal (Get-TuiFrameSequence -Lines @('Done'))
        Assert-True (@($terminal.Erases | Where-Object { $_ -ne 'default' }).Count -eq 0) 'Erase inherited a selected background'
        Assert-True ($terminal.Background -eq 'default') 'Frame left a background active'
        Assert-TestRow $terminal 0 'Done'
    }
} finally { $env:NO_COLOR = $originalColor }
Write-Host ("{0} passed; {1} failed." -f $script:Passed, $script:Failures.Count)
if ($script:Failures.Count) { throw ($script:Failures -join "`n") }
