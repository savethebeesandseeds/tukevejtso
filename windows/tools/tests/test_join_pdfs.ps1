param([string] $Python)

# Run with Windows PowerShell 5.1; no Pester dependency is required.
$ErrorActionPreference = 'Stop'
$entry = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\join-pdfs.ps1'))
. $entry
if (-not $Python) {
    $Python = Find-PdfPython
}
$script:PdfPython = $Python
$script:TestRoot = Join-Path $PSScriptRoot ('.tmp-terminal-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($script:TestRoot)
$script:PdfStatePath = Join-Path $script:TestRoot 'settings\state.json'
$originalColor = $env:NO_COLOR
$originalPython = $env:TUKEVEJTSO_PDF_PYTHON
$env:NO_COLOR = '1'
$env:TUKEVEJTSO_PDF_PYTHON = $Python
$script:Passed = 0
$script:Failures = New-Object 'System.Collections.Generic.List[string]'

function Assert-True([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}
function Assert-Sequence($Actual, $Expected, [string] $Message) {
    $a = @($Actual) -join '|'
    $e = @($Expected) -join '|'
    if ($a -cne $e) { throw "$Message -- expected [$e], received [$a]" }
}
function Test-Case([string] $Name, [scriptblock] $Body) {
    try { & $Body; $script:Passed++; Write-Host "PASS $Name" }
    catch { $script:Failures.Add("$Name : $($_.Exception.Message)"); Write-Host "FAIL $Name : $($_.Exception.Message)`n$($_.ScriptStackTrace)" }
}
function Assert-Viewport([string] $Frame, [int] $First, [int] $Last, [int] $Total, [bool] $Above, [bool] $Below) {
    Assert-True ($Frame.Contains(('Rows {0}-{1} of {2} |' -f $First, $Last, $Total))) ('Unexpected visible rows; expected {0}-{1} of {2}' -f $First, $Last, $Total)
    $lines = @($Frame -split "`n")
    $top = [string][char]0x2191 + ' More above'
    $bottom = [string][char]0x2193 + ' More below'
    Assert-True ($lines[5].Contains($top) -eq $Above) 'The upper border indicator must reflect content above the visible rows'
    $rowCount = Get-PdfPageSize
    Assert-True ($lines[6 + $rowCount].Contains($bottom) -eq $Below) 'The lower border indicator must reflect content below the visible rows'
}
function New-TestState {
    return [pscustomobject]@{ folder = $script:InputFolder; recursive = $false; selected = @(); output = ''; lastOutput = '' }
}
function Set-Keys([string[]] $Keys, [string[]] $Answers = @()) {
    $script:Keys = New-Object 'System.Collections.Generic.Queue[string]'
    foreach ($key in $Keys) { $script:Keys.Enqueue($key) }
    $script:Answers = New-Object 'System.Collections.Generic.Queue[string]'
    foreach ($answer in $Answers) { $script:Answers.Enqueue($answer) }
    $script:Frames = New-Object 'System.Collections.Generic.List[string]'
}
function Read-PdfKey {
    if (-not $script:Keys.Count) { throw 'Scripted keys exhausted (unexpected UI transition).' }
    $name = $script:Keys.Dequeue()
    if ($name -in @('/', '+', '-', '=')) { return [pscustomobject]@{ Key = 'Oem2'; KeyChar = $name } }
    return [pscustomobject]@{ Key = $name; KeyChar = [char]0 }
}
function Read-PdfText([string] $Label, [string] $Current = '') {
    if (-not $script:Answers.Count) { throw "Unexpected text prompt: $Label" }
    return $script:Answers.Dequeue()
}
function Write-TuiFrame([string[]] $Lines, [switch] $Initial) {
    $script:Frames.Add((($Lines -join "`n") -replace ([string][char]27 + '\[[0-9;]*m'), ''))
}
# Geometry belongs to the real terminal; keep controller tests runnable under
# redirected automation handles while retaining the actual rendering content.
function Get-PdfPageSize([int] $Overhead = 15) { return 10 }
function Get-PdfLineWidth { return 99 }
function Format-PdfLine([string] $Text, [string] $Color = '#d7d7d7', [switch] $Active) { return $Text }
function Clear-Host { }
function Set-FolderDialog([AllowNull()][string] $Result) {
    $script:DialogResult = $Result
    $script:DialogCalls = 0
    $script:DialogInitial = $null
}
function Show-PdfFolderDialog([string] $Initial = '') {
    $script:DialogCalls++
    $script:DialogInitial = $Initial
    return $script:DialogResult
}
function Invoke-TestChild([string] $Arguments) {
    $code = "[Console]::OutputEncoding = New-Object Text.UTF8Encoding(`$false); & '" + $entry.Replace("'", "''") + "' " + $Arguments
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $info.Arguments = '-NoProfile -ExecutionPolicy Bypass -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $info.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
    $proc = New-Object Diagnostics.Process
    $proc.StartInfo = $info
    try {
        [void]$proc.Start()
        $stdout = $proc.StandardOutput.ReadToEndAsync()
        $stderr = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit(30000)) { $proc.Kill(); throw 'CLI did not exit within 30 seconds.' }
        return [pscustomobject]@{ exitCode = $proc.ExitCode; output = $stdout.GetAwaiter().GetResult(); error = $stderr.GetAwaiter().GetResult() }
    } finally { $proc.Dispose() }
}

try {
    # Construct Unicode independently of the script file encoding, because PS5.1
    # interprets UTF-8 files without a BOM using the local ANSI code page.
    $unicode = 'M' + [char]0x171 + 'hely ' + [char]0x6771 + [char]0x4eac
    $script:InputFolder = Join-Path $script:TestRoot $unicode
    [void][IO.Directory]::CreateDirectory((Join-Path $script:InputFolder 'nested'))
    $script:UnicodePdf = '3-' + [char]0x151 + 'r.pdf'
    foreach ($name in @('1-alpha.pdf', '2-beta.PDF', $script:UnicodePdf, 'notes.txt', 'nested\4-child.pdf')) {
        [IO.File]::WriteAllText((Join-Path $script:InputFolder $name), 'scan fixture')
    }
    $script:TreeFolder = Join-Path $script:TestRoot 'tree'
    $script:TreeUnicodePdf = '2-' + [char]0x151 + 'r.pdf'
    $script:TreeNestedPdf = '02-letters\deep\' + $script:TreeUnicodePdf
    foreach ($directory in @('02-letters\deep', '04-folder')) {
        [void][IO.Directory]::CreateDirectory((Join-Path $script:TreeFolder $directory))
    }
    foreach ($name in @('01-root.pdf', $script:TreeNestedPdf, '03-root.pdf', '04-folder\05-leaf.pdf')) {
        [IO.File]::WriteAllText((Join-Path $script:TreeFolder $name), 'tree scan fixture')
    }

    $script:ScrollFolder = Join-Path $script:TestRoot 'scroll'
    [void][IO.Directory]::CreateDirectory($script:ScrollFolder)
    foreach ($number in 1..6) {
        [IO.File]::WriteAllText((Join-Path $script:ScrollFolder ($number.ToString() + '-item.pdf')), 'scroll scan fixture')
    }

    Test-Case 'PowerShell 5.1 runtime' {
        Assert-True ($PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -eq 1) 'Run this test with powershell.exe, not pwsh.'
    }
    Test-Case 'Windows Common Item Dialog wrapper compiles on PowerShell 5.1' {
        Add-Type -Path (Join-Path (Split-Path -Parent $entry) 'pdf-folder-picker.cs')
        Assert-True ($null -ne ('Tukevejtso.PdfFolderPicker' -as [type])) 'Native folder picker type was not loaded'
    }
    Test-Case 'UTF-8 JSON bridge and first scan with empty previous output' {
        $state = New-TestState
        $files = Update-PdfFiles $state
        Assert-Sequence ($files | ForEach-Object relative) @('1-alpha.pdf', '2-beta.PDF', $script:UnicodePdf) 'Only PDFs in natural order should be shown'
        Assert-True ($state.folder -ceq $script:InputFolder) 'Unicode folder was damaged in JSON bridge'
        Assert-True ($files[2].path -ceq (Join-Path $script:InputFolder $script:UnicodePdf)) 'Unicode PDF path was damaged'
        Assert-True ($state.selected.Count -eq 0) 'Initial scan should not implicitly select files'
    }
    Test-Case 'Recursive default migrates older settings once and retains an explicit root-only preference' {
        $previousStatePath = $script:PdfStatePath
        try {
            $script:PdfStatePath = Join-Path $script:TestRoot 'migration.json'
            Assert-True ((Read-PdfState).recursive) 'New settings must include subfolders by default'
            $legacy = [ordered]@{ folder = $script:InputFolder; recursive = $false; selected = @($script:UnicodePdf, '1-alpha.pdf'); lastOutput = 'previous.pdf' }
            [IO.File]::WriteAllText($script:PdfStatePath, ($legacy | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
            $migrated = Read-PdfState
            Assert-True ($migrated.recursive -and $migrated.folder -ceq $script:InputFolder -and $migrated.lastOutput -ceq 'previous.pdf') 'Older settings must enable recursion while retaining the confirmed folder and previous result'
            Assert-Sequence $migrated.selected @($script:UnicodePdf, '1-alpha.pdf') 'Migration must preserve Unicode selection and merge order'
            $migrated.recursive = $false
            Save-PdfState $migrated
            $saved = Get-Content -LiteralPath $script:PdfStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
            Assert-True ($saved.version -eq 2 -and -not (Read-PdfState).recursive) 'Version 2 must preserve an explicit root-only preference on subsequent launches'
            Assert-Sequence (Read-PdfState).selected $migrated.selected 'Saving migrated settings must retain selection order'
        } finally { $script:PdfStatePath = $previousStatePath }
    }
    Test-Case 'Remember folder, recursive scope, and selection order' {
        $state = New-TestState
        $state.recursive = $true
        $state.selected = @($script:UnicodePdf, '1-alpha.pdf', 'nested\4-child.pdf')
        $state.output = Get-PdfOutputPath -Directory $state.folder -Selected $state.selected
        Save-PdfState $state
        $saved = Read-PdfState
        Assert-True ($saved.folder -ceq $state.folder -and $saved.recursive -eq $true) 'Settings did not round trip'
        Assert-Sequence $saved.selected $state.selected 'Selection order must survive restart'
        $saved.selected = @('2-beta.PDF')
        Save-PdfState $saved
        Assert-Sequence (Read-PdfState).selected @('2-beta.PDF') ('Replacing existing settings must work: ' + $script:PdfNotice)
    }
    Test-Case 'Automatic name uses ordered basenames and first words in the search root' {
        $actual = Get-PdfOutputPath -Directory $script:InputFolder -Selected @('Application form.pdf', 'nested\Passport copy.PDF', 'Bank_statement.pdf', 'child/Payment-receipt.pdf')
        Assert-True ($actual -ceq (Join-Path $script:InputFolder 'Application form - Passport - Bank - Payment.pdf')) 'Automatic name must keep the first full stem and append the first word of each later basename'
        $unicodeStem = [IO.Path]::GetFileNameWithoutExtension($script:UnicodePdf)
        $actual = Get-PdfOutputPath -Directory $script:InputFolder -Selected @(('nested\' + $script:UnicodePdf), 'nested\   _-Passport copy.pdf')
        Assert-True ($actual -ceq (Join-Path $script:InputFolder ($unicodeStem + ' - Passport.pdf'))) 'Unicode first stems and leading word separators must be handled without folder names'
        Assert-True ((Get-PdfOutputPath -Directory $script:InputFolder -Selected @()) -ceq '') 'No selection should leave the output pending'
    }
    Test-Case 'Automatic name chooses an unused suffix and preserves existing files' {
        $existing = Join-Path $script:InputFolder '1-alpha (2).pdf'
        try {
            [IO.File]::WriteAllText($existing, 'previous output')
            $actual = Get-PdfOutputPath -Directory $script:InputFolder -Selected @('1-alpha.pdf')
            Assert-True ($actual -ceq (Join-Path $script:InputFolder '1-alpha (3).pdf')) 'A single selected source and prior output must both be protected by an available suffix'
            Assert-True ([IO.File]::ReadAllText((Join-Path $script:InputFolder '1-alpha.pdf')) -ceq 'scan fixture') 'Source file was changed while choosing the name'
            Assert-True ([IO.File]::ReadAllText($existing) -ceq 'previous output') 'Existing output was changed while choosing the name'
        } finally { if (Test-Path -LiteralPath $existing) { Remove-Item -LiteralPath $existing } }
    }
    Test-Case 'Overlong automatic output reports an error without truncating the name' {
        $failure = $null
        try { [void](Get-PdfOutputPath -Directory $script:InputFolder -Selected @((('a' * 150) + '.pdf'), (('b' * 150) + '.pdf'))) } catch { $failure = $_ }
        Assert-True ($null -ne $failure -and $failure.Exception.Message -match 'long|240') 'An overlong output must produce an actionable error'
    }
    Test-Case 'Search select-all and clear-visible preserve hidden selections' {
        $state = New-TestState
        Set-Keys @('Spacebar', '/', 'A', 'N', 'Q') @('beta')
        Invoke-PdfJoinMenu $state
        Assert-Sequence $state.selected @('1-alpha.pdf') 'Clear visible must retain selected files hidden by search'
        Assert-True ($state.output -ceq (Join-Path $script:InputFolder '1-alpha (2).pdf')) 'Changing the selection must update the automatic name'
        Assert-True (($script:Frames -join "`n") -match 'Search: beta \| 2 selected') 'Selecting all search results should add to the existing selection'
        Assert-True ($script:Keys.Count -eq 0) 'Menu exited before consuming the interaction'
    }
    Test-Case 'Merge order persists after moving a selected PDF earlier' {
        $state = New-TestState
        Set-Keys @('A', 'Tab', 'End', '-', 'Q')
        Invoke-PdfJoinMenu $state
        Assert-Sequence $state.selected @('1-alpha.pdf', $script:UnicodePdf, '2-beta.PDF') 'Reordering should change merge order'
        Assert-True ($state.output -ceq (Join-Path $script:InputFolder '1-alpha - 3 - 2.pdf')) 'Reordering must update the output name to the new merge order'
        Assert-Sequence (Read-PdfState).selected $state.selected 'Reordering must be saved on quit'
    }
    Test-Case 'Recursion reveals child PDFs and removes out-of-scope selections' {
        $state = New-TestState
        Set-Keys @('A', 'R', 'A', 'R', 'Q')
        Invoke-PdfJoinMenu $state
        Assert-True (($script:Frames -join "`n") -match 'Folder \+ all subfolders \| 4 PDFs') 'Recursive toggle did not expose nested PDFs'
        Assert-True (($script:Frames -join "`n") -match '4 selected') 'Nested PDF was not selectable'
        Assert-True (-not $state.recursive) 'Second recursive toggle did not restore flat scope'
        Assert-Sequence $state.selected @('1-alpha.pdf', '2-beta.PDF', $script:UnicodePdf) 'Hidden out-of-scope PDF must not remain selected'
    }
    Test-Case 'Tree headings are context only and arrow selection skips them' {
        $state = New-TestState
        $state.folder = $script:TreeFolder
        $state.recursive = $true
        Set-Keys @('DownArrow', 'Spacebar', 'UpArrow', 'Spacebar', 'Q')
        Invoke-PdfJoinMenu $state
        Assert-Sequence $state.selected @($script:TreeNestedPdf, '01-root.pdf') 'Down and Up must move between PDFs across ancestor headings'
        $frame = $script:Frames[0]
        $headings = @($frame -split "`n" | Where-Object { $_.Contains('02-letters/') -or $_.Contains('deep/') })
        Assert-True ($headings.Count -eq 2 -and -not (($headings -join "`n") -match '\[[ x]\]')) 'Ancestor folder headings must be visible without selection checkboxes'
        $leafLine = @($frame -split "`n" | Where-Object { $_ -match '\[[ x]\]' -and $_.Contains($script:TreeUnicodePdf) })
        Assert-True ($leafLine.Count -eq 1 -and $leafLine[0].Contains([string][char]0x2514) -and -not $leafLine[0].Contains('02-letters\')) 'Nested Unicode PDFs must appear as leaves with a tree branch, without repeating their relative path'

        Set-Keys @('/', 'Q') @($script:TreeUnicodePdf)
        Invoke-PdfJoinMenu $state
        $filtered = $script:Frames[$script:Frames.Count - 1]
        Assert-True ($filtered.Contains('02-letters/') -and $filtered.Contains('deep/') -and $filtered.Contains($script:TreeUnicodePdf)) 'Filtering a nested PDF must retain all its ancestor headings'
        Assert-True (-not $filtered.Contains('04-folder/') -and $filtered -match 'of 3 \| 1 PDFs') 'Filtering should show only the matching leaf and its ancestors'
        Assert-Sequence $state.selected @($script:TreeNestedPdf, '01-root.pdf') 'Filtering must preserve a selected PDF hidden by the search'

        Set-Keys @('Tab', 'Enter', 'Escape', 'Q')
        Invoke-PdfJoinMenu $state
        $orderedFrames = @($script:Frames | Where-Object { $_ -match 'PDF JOIN / (Merge order|REVIEW / Enter to join)' })
        Assert-True ($orderedFrames.Count -ge 2) 'Tab and Enter must show merge-order and review views'
        foreach ($orderedFrame in $orderedFrames) {
            Assert-True ($orderedFrame.Contains($script:TreeNestedPdf) -and -not $orderedFrame.Contains('02-letters/') -and $orderedFrame -match 'of 2 \| 2 PDFs') 'Merge order and review must remain flat lists of selected relative paths'
        }
    }
    Test-Case 'Arrow navigation scrolls only at an edge and does not snap when reversing' {
        function Get-PdfPageSize([int] $Overhead = 15) { return 3 }
        $state = New-TestState
        $state.folder = $script:ScrollFolder
        Set-Keys @('DownArrow', 'DownArrow', 'DownArrow', 'UpArrow', 'UpArrow', 'UpArrow', 'Q')
        Invoke-PdfJoinMenu $state
        foreach ($index in 0..2) { Assert-Viewport $script:Frames[$index] 1 3 6 $false $true }
        foreach ($index in 3..5) { Assert-Viewport $script:Frames[$index] 2 4 6 $true $true }
        Assert-Viewport $script:Frames[6] 1 3 6 $false $true
        Assert-True (-not (($script:Frames -join "`n").Contains('Rows 4-6'))) 'Moving to the fourth PDF must not jump to a new page'
    }
    Test-Case 'Scroll arrows show available content at the top middle and bottom' {
        function Get-PdfPageSize([int] $Overhead = 15) { return 3 }
        $state = New-TestState
        $state.folder = $script:ScrollFolder
        Set-Keys @('End', 'UpArrow', 'UpArrow', 'UpArrow', 'Home', 'Q')
        Invoke-PdfJoinMenu $state
        Assert-Viewport $script:Frames[0] 1 3 6 $false $true
        foreach ($index in 1..3) { Assert-Viewport $script:Frames[$index] 4 6 6 $true $false }
        Assert-Viewport $script:Frames[4] 3 5 6 $true $true
        Assert-Viewport $script:Frames[5] 1 3 6 $false $true

        $state = New-TestState
        Set-Keys @('/', 'Q') @('no-such-pdf')
        Invoke-PdfJoinMenu $state
        Assert-Viewport $script:Frames[0] 1 3 3 $false $false
        Assert-Viewport $script:Frames[1] 0 0 0 $false $false
        Assert-True ($script:Frames[1].Contains('No PDFs here.')) 'An empty search must keep its explanatory message'
    }
    Test-Case 'Page keys move one PDF and tree scrolling retains the correct nested leaf' {
        function Get-PdfPageSize([int] $Overhead = 15) { return 3 }
        $state = New-TestState
        $state.folder = $script:TreeFolder
        $state.recursive = $true
        Set-Keys @('PageDown', 'Spacebar', 'PageDown', 'PageUp', 'PageUp', 'End', 'PageUp', 'Spacebar', 'Q')
        Invoke-PdfJoinMenu $state
        Assert-Sequence $state.selected @($script:TreeNestedPdf, '03-root.pdf') 'Page keys must move exactly one PDF in either direction and skip folder headings'
        Assert-Viewport $script:Frames[0] 1 3 7 $false $true
        Assert-Viewport $script:Frames[1] 2 4 7 $true $true
        Assert-Viewport $script:Frames[3] 3 5 7 $true $true
        Assert-Viewport $script:Frames[4] 3 5 7 $true $true
        Assert-Viewport $script:Frames[5] 1 3 7 $false $true
        Assert-Viewport $script:Frames[6] 5 7 7 $true $false
        Assert-Viewport $script:Frames[7] 5 7 7 $true $false
        $selectedLeaf = @($script:Frames[2] -split "`n" | Where-Object { $_ -match '\[x\]\s+1\s+' -and $_.Contains($script:TreeUnicodePdf) })
        Assert-True ($selectedLeaf.Count -eq 1 -and $selectedLeaf[0].Contains([string][char]0x2514)) 'The scrolled nested leaf must keep its Unicode label, tree branch, and selection number'
    }
    Test-Case 'Search and view changes start at the beginning after scrolling' {
        function Get-PdfPageSize([int] $Overhead = 15) { return 3 }
        $state = New-TestState
        $state.folder = $script:ScrollFolder
        Set-Keys @('End', '/', 'A', 'End', 'Tab', 'End', 'Tab', 'End', 'Enter', 'Escape', 'Q') @('.pdf')
        Invoke-PdfJoinMenu $state
        Assert-Viewport $script:Frames[1] 4 6 6 $true $false
        Assert-Viewport $script:Frames[2] 1 3 6 $false $true
        foreach ($index in @(5, 7, 9, 10)) { Assert-Viewport $script:Frames[$index] 1 3 6 $false $true }
        Assert-True ($script:Frames[5].Contains('PDF JOIN / Merge order') -and $script:Frames[7].Contains('PDF JOIN / PDF tree') -and $script:Frames[9].Contains('REVIEW / Enter to join')) 'View resets must apply to merge order, the tree, and review'
        Assert-True ($state.selected.Count -eq 6) 'Scrolling and changing views must preserve selected PDFs'
    }
    Test-Case 'Changing folder resets the scroll position' {
        function Get-PdfPageSize([int] $Overhead = 15) { return 3 }
        $state = New-TestState
        $state.folder = $script:ScrollFolder
        Set-FolderDialog $script:InputFolder
        Set-Keys @('End', 'F', 'Q')
        Invoke-PdfJoinMenu $state
        Assert-Viewport $script:Frames[1] 4 6 6 $true $false
        Assert-Viewport $script:Frames[2] 1 3 3 $false $false
        Assert-True ($state.folder -ceq $script:InputFolder) 'The confirmed folder must replace the previously scrolled folder'
    }
    Test-Case 'Refresh clamps the viewport when the list becomes shorter' {
        function Get-PdfPageSize([int] $Overhead = 15) { return 3 }
        $state = New-TestState
        $state.folder = $script:ScrollFolder
        $script:ScrollScanFiles = Update-PdfFiles $state
        $script:ScrollScanCalls = 0
        function Update-PdfFiles($State) {
            $script:ScrollScanCalls++
            if ($script:ScrollScanCalls -eq 1) { return ,$script:ScrollScanFiles }
            return ,@($script:ScrollScanFiles | Select-Object -First 4)
        }
        Set-Keys @('End', 'F5', 'Q')
        Invoke-PdfJoinMenu $state
        Assert-Viewport $script:Frames[1] 4 6 6 $true $false
        Assert-Viewport $script:Frames[2] 2 4 4 $true $false
        Assert-True ($script:Frames[2].Contains('4-item.pdf |')) 'Refresh must leave focus on an available PDF'
    }
    Test-Case 'Refresh derives the name from surviving inputs and ignores a stale saved destination' {
        $state = New-TestState
        $state.selected = @('missing.pdf', '2-beta.PDF', '1-alpha.pdf')
        $state.output = Join-Path $script:TestRoot 'old-destination.pdf'
        Save-PdfState $state
        $state = Read-PdfState
        Set-Keys @('F5', 'O', 'Q')
        Invoke-PdfJoinMenu $state
        Assert-Sequence $state.selected @('2-beta.PDF', '1-alpha.pdf') 'Refresh must retain only available selected PDFs'
        Assert-True ($state.output -ceq (Join-Path $script:InputFolder '2-beta - 1.pdf')) 'A saved destination outside the search folder must never determine the new output'
        Assert-True (-not (($script:Frames -join "`n") -match '\| O Output')) 'The menu should not offer an output destination override'
    }
    Test-Case 'Review shows full selection despite search and Escape returns without merging' {
        $state = New-TestState
        Set-Keys @('A', '/', 'Enter', 'Escape', 'Q') @('beta')
        Invoke-PdfJoinMenu $state
        $review = @($script:Frames | Where-Object { $_ -match 'REVIEW / Enter to join' })
        Assert-True ($review.Count -eq 1 -and $review[0] -match '1-alpha.pdf' -and $review[0] -match '2-beta.PDF') 'Review must show all selected PDFs'
        Assert-True (-not (Test-Path -LiteralPath $state.output)) 'Review cancellation must not create an output'
        Assert-True ($script:Frames[$script:Frames.Count - 1] -match 'Merge order') 'Escape should return from review to the list'
    }
    Test-Case 'Windows picker uses previous folder only as its initial view' {
        Set-FolderDialog $script:InputFolder
        $chosen = Select-PdfFolder $script:TestRoot
        Assert-True ($script:DialogCalls -eq 1 -and $script:DialogInitial -ceq $script:TestRoot) 'Previous folder must be passed to the dialog as its initial view'
        Assert-True ($chosen -ceq $script:InputFolder) 'Unicode folder returned by the dialog was not selected'
    }
    Test-Case 'Empty or unavailable previous folder does not assume another folder' {
        foreach ($initial in @('', (Join-Path $script:TestRoot 'missing'))) {
            Set-FolderDialog $null
            Assert-True ($null -eq (Select-PdfFolder $initial)) 'Dialog cancellation should not select any folder'
            Assert-True ($script:DialogCalls -eq 1 -and $script:DialogInitial -ceq '') 'Missing previous folder must not be replaced with Documents or another assumed folder'
        }
    }
    Test-Case 'Windows picker validates the returned folder' {
        Set-FolderDialog (Join-Path $script:InputFolder 'notes.txt')
        $failure = $null
        try { [void](Select-PdfFolder $script:InputFolder) } catch { $failure = $_ }
        Assert-True ($null -ne $failure -and $failure.Exception.Message -match 'filesystem folder') 'A file must not be accepted as a folder'
    }
    Test-Case 'Every interactive launch confirms the saved folder and preserves its selections' {
        $state = New-TestState
        $state.selected = @('2-beta.PDF', '1-alpha.pdf')
        $state.output = Join-Path $script:InputFolder 'custom.pdf'
        Set-FolderDialog $script:InputFolder
        $first = Initialize-PdfSession -State $state
        $second = Initialize-PdfSession -State $state
        Assert-True ($script:DialogCalls -eq 2 -and $script:DialogInitial -ceq $script:InputFolder) 'Saved folder must still require the Windows dialog on every interactive launch'
        Assert-Sequence $second.selected @('2-beta.PDF', '1-alpha.pdf') 'Choosing the same folder should preserve selection order'
        Assert-True ($first.output -ceq (Join-Path $script:InputFolder '2-beta - 1.pdf')) 'Choosing the same folder should derive the output from the restored selection'
    }
    Test-Case 'Startup cancellation leaves settings and state unchanged without scanning' {
        $state = New-TestState
        $state.selected = @('2-beta.PDF', '1-alpha.pdf')
        $state.output = Join-Path $script:InputFolder 'custom.pdf'
        Save-PdfState $state
        $beforeState = $state | ConvertTo-Json -Depth 5
        $beforeSaved = [Convert]::ToBase64String([IO.File]::ReadAllBytes($script:PdfStatePath))
        function Save-PdfState { throw 'Cancellation tried to save settings.' }
        function Invoke-PdfBackend { throw 'Cancellation tried to scan PDFs.' }
        Set-FolderDialog $null
        $result = Initialize-PdfSession -State $state -Recursive
        Assert-True ($null -eq $result) 'Startup cancellation must return no session'
        Assert-True (($state | ConvertTo-Json -Depth 5) -ceq $beforeState) 'Startup cancellation changed in-memory settings'
        Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($script:PdfStatePath)) -ceq $beforeSaved) 'Startup cancellation changed saved settings'
    }
    Test-Case 'Choosing another folder resets selection and leaves the output pending' {
        $state = New-TestState
        $state.selected = @('1-alpha.pdf')
        $state.output = Join-Path $script:InputFolder 'old.pdf'
        $state.lastOutput = Join-Path $script:InputFolder 'previous.pdf'
        $child = Join-Path $script:InputFolder 'nested'
        Set-FolderDialog $child
        $result = Initialize-PdfSession -State $state -Recursive
        Assert-True ($result.folder -ceq $child -and $result.recursive) 'Chosen folder and explicit recursion were not applied'
        Assert-True ($result.selected.Count -eq 0 -and $result.lastOutput -ceq '') 'Selection and previous output must be cleared when changing folders'
        Assert-True ($result.output -ceq '') 'Output must wait until PDFs are selected in the new folder'
    }
    Test-Case 'Explicit startup folder and NoMenu bypass the Windows picker' {
        Set-FolderDialog $null
        $state = New-TestState
        $state.recursive = $true
        $explicit = Initialize-PdfSession -State $state -Folder ('"' + $script:InputFolder + '"') -Recursive:$false
        Assert-True ($explicit.folder -ceq $script:InputFolder -and -not $explicit.recursive) 'Explicit folder or recursion override was ignored'
        $saved = Initialize-PdfSession -State (New-TestState) -NoMenu
        Assert-True ($saved.folder -ceq $script:InputFolder) 'NoMenu should accept a previously confirmed folder'
        Assert-True ($script:DialogCalls -eq 0) 'An explicit folder or NoMenu must not open the picker'
    }
    Test-Case 'NoMenu with no remembered folder fails without choosing a default' {
        $state = New-TestState
        $state.folder = ''
        Set-FolderDialog $null
        $failure = $null
        try { [void](Initialize-PdfSession -State $state -NoMenu) } catch { $failure = $_ }
        Assert-True ($null -ne $failure -and $failure.Exception.Message -match 'Specify a folder') 'NoMenu without a remembered folder needs an actionable error'
        Assert-True ($script:DialogCalls -eq 0 -and $state.folder -ceq '') 'NoMenu must not select or assume a folder'
    }
    Test-Case 'NoMenu rejects an unavailable remembered folder without opening the picker' {
        $state = New-TestState
        $state.folder = Join-Path $script:TestRoot 'missing'
        Set-FolderDialog $null
        $failure = $null
        try { [void](Initialize-PdfSession -State $state -NoMenu) } catch { $failure = $_ }
        Assert-True ($null -ne $failure) 'NoMenu should report that the remembered folder no longer exists'
        Assert-True ($script:DialogCalls -eq 0 -and $state.folder -ceq (Join-Path $script:TestRoot 'missing')) 'NoMenu must not replace an unavailable saved folder'
    }
    Test-Case 'F opens the Windows picker and cancellation keeps the current selection' {
        $state = New-TestState
        $state.selected = @('1-alpha.pdf')
        Set-FolderDialog $null
        Set-Keys @('F', 'Q')
        Invoke-PdfJoinMenu $state
        Assert-True ($script:DialogCalls -eq 1 -and $script:DialogInitial -ceq $script:InputFolder) 'F must open the Windows picker at the current folder'
        Assert-Sequence $state.selected @('1-alpha.pdf') 'Cancelling F should retain the selected PDFs'
        Assert-True ($state.folder -ceq $script:InputFolder) 'Cancelling F changed the current folder'
    }
    Test-Case 'P still accepts a quoted Unicode folder path without opening the picker' {
        $state = New-TestState
        $state.folder = Join-Path $script:InputFolder 'nested'
        $state.selected = @('4-child.pdf')
        Set-FolderDialog $null
        Set-Keys @('P', 'Q') @(('"' + $script:InputFolder + '"'))
        Invoke-PdfJoinMenu $state
        Assert-True ($state.folder -ceq $script:InputFolder) 'Pasted Unicode folder was not selected'
        Assert-True ($script:DialogCalls -eq 0 -and $state.selected.Count -eq 0) 'Pasting another folder should clear selection without opening the dialog'
    }
    Test-Case 'F confirms another folder and resets its selection and output' {
        $state = New-TestState
        $state.selected = @('1-alpha.pdf')
        $state.output = Join-Path $script:InputFolder 'custom.pdf'
        $child = Join-Path $script:InputFolder 'nested'
        Set-FolderDialog $child
        Set-Keys @('F', 'Q')
        Invoke-PdfJoinMenu $state
        Assert-True ($state.folder -ceq $child -and $state.selected.Count -eq 0) 'The folder confirmed in the picker was not applied'
        Assert-True ($state.output -ceq '') 'Changing folder should leave output pending until files are selected'
        Assert-True (($script:Frames -join "`n") -match '4-child.pdf') 'Files were not refreshed after choosing the new folder'
    }
    Test-Case 'UI joins recursive PDFs in chosen order into the search root and remembers success' {
        $previousInput = $script:InputFolder
        try {
            $script:InputFolder = Join-Path $script:TestRoot ('merge ' + $unicode)
            [void][IO.Directory]::CreateDirectory($script:InputFolder)
            [void][IO.Directory]::CreateDirectory((Join-Path $script:InputFolder 'nested'))
            $fixtureCode = @'
import sys
from pathlib import Path
from pypdf import PdfWriter
folder = Path(sys.argv[1])
for name, width in [('Application form.pdf', 120), ('Bank_statement.pdf', 220), ('nested/Passport copy.PDF', 320)]:
    writer = PdfWriter()
    writer.add_blank_page(width=width, height=300)
    writer.write(str(folder / name))
    writer.close()
'@
            & $Python -X utf8 -c $fixtureCode $script:InputFolder
            Assert-True ($LASTEXITCODE -eq 0) 'Could not generate real PDF fixtures'
            $state = New-TestState
            Set-Keys @('R', 'A', 'Tab', 'End', '-', 'Enter', 'Enter', 'Spacebar', 'Q')
            Invoke-PdfJoinMenu $state
            $created = Join-Path $script:InputFolder 'Application form - Passport - Bank.pdf'
            Assert-True (Test-Path -LiteralPath $created) 'UI confirmation did not create the automatically named PDF in the search root'
            $widths = & $Python -X utf8 -c 'import json,sys; from pypdf import PdfReader; print(json.dumps([int(p.mediabox.width) for p in PdfReader(sys.argv[1]).pages]))' $created
            Assert-True ($LASTEXITCODE -eq 0) 'Created PDF could not be read'
            Assert-Sequence ($widths | ConvertFrom-Json) @(120, 320, 220) 'Merged pages must follow the edited UI order'
            $saved = Read-PdfState
            Assert-True ($saved.lastOutput -ceq $created) 'Success should remember the PDF that was created'
            Assert-True ($state.output -ceq (Join-Path $script:InputFolder 'Application form - Passport - Bank (2).pdf')) 'Success should remember the next available automatic filename'
            Assert-Sequence $saved.selected @('Application form.pdf', 'nested\Passport copy.PDF', 'Bank_statement.pdf') 'Success should preserve input selections and their order'
            Assert-True ($script:Keys.Count -eq 1 -and $script:Keys.Peek() -ceq 'Q') 'Success should consume one closing key and return without reopening selection'
            Assert-True ($script:Frames[$script:Frames.Count - 1] -match 'REVIEW / Enter to join') 'Success must not redraw selection after the review'

            # A single-file join necessarily collides with its source filename.
            # A preexisting numbered result must remain unchanged as well.
            $source = Join-Path $script:InputFolder 'Application form.pdf'
            $sourceBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes($source))
            $existing = Join-Path $script:InputFolder 'Application form (2).pdf'
            [IO.File]::WriteAllText($existing, 'keep prior result')
            $state = New-TestState
            $state.selected = @('Application form.pdf')
            $state.output = $source
            Set-Keys @('Enter', 'Enter', 'Spacebar', 'Q')
            Invoke-PdfJoinMenu $state
            $single = Join-Path $script:InputFolder 'Application form (3).pdf'
            Assert-True (Test-Path -LiteralPath $single) 'Single-file merge must choose a free suffix even with a stale saved output matching the source'
            Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($source)) -ceq $sourceBefore) 'Single-file merge changed its source'
            Assert-True ([IO.File]::ReadAllText($existing) -ceq 'keep prior result') 'Single-file merge replaced the existing numbered result'
            $widths = & $Python -X utf8 -c 'import json,sys; from pypdf import PdfReader; print(json.dumps([int(p.mediabox.width) for p in PdfReader(sys.argv[1]).pages]))' $single
            Assert-True ($LASTEXITCODE -eq 0) 'Single-file result could not be read'
            Assert-Sequence ($widths | ConvertFrom-Json) @(120) 'Single-file result must contain its selected source page'
            Assert-True ($script:Keys.Count -eq 1 -and $script:Keys.Peek() -ceq 'Q') 'Single-file success should consume one closing key and return without reopening selection'
            Assert-True ($script:Frames[$script:Frames.Count - 1] -match 'REVIEW / Enter to join') 'Single-file success must not redraw selection after the review'
        } finally { $script:InputFolder = $previousInput }
    }
    Test-Case 'Help exits successfully without a terminal' {
        $result = Invoke-TestChild '-Help'
        Assert-True ($result.exitCode -eq 0 -and $result.output -match 'tk join-pdfs' -and $result.output -match '-NoMenu') ('Help failed: ' + $result.output + $result.error)
        Assert-True ($result.output -notmatch '-Output|O for output') 'Help should not offer an output override'
    }
    Test-Case 'NoMenu produces recursive Unicode JSON without saving or creating PDFs' {
        # The public entry point can read existing user preferences. It must
        # never write them in NoMenu mode; all parameters affecting scan are explicit.
        $realSettings = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'tukevejtso\pdf-join.json'
        $before = if (Test-Path -LiteralPath $realSettings) { [Convert]::ToBase64String([IO.File]::ReadAllBytes($realSettings)) } else { $null }
        $beforeFiles = @(Get-ChildItem -LiteralPath $script:InputFolder -Recurse -File | ForEach-Object FullName)
        $quotedFolder = "'" + $script:InputFolder.Replace("'", "''") + "'"
        $result = Invoke-TestChild ("-Folder $quotedFolder -Recursive -NoMenu")
        Assert-True ($result.exitCode -eq 0) ('NoMenu failed: ' + $result.output + $result.error)
        $json = $result.output | ConvertFrom-Json
        Assert-True ($json.ok -and $json.files.Count -eq 4 -and $json.folder -ceq $script:InputFolder) 'NoMenu did not return valid recursive Unicode JSON'
        $after = if (Test-Path -LiteralPath $realSettings) { [Convert]::ToBase64String([IO.File]::ReadAllBytes($realSettings)) } else { $null }
        Assert-True ($before -ceq $after) 'NoMenu unexpectedly changed real settings'
        Assert-Sequence @(Get-ChildItem -LiteralPath $script:InputFolder -Recurse -File | ForEach-Object FullName) $beforeFiles 'NoMenu unexpectedly changed the folder contents'
    }
} finally {
    $env:NO_COLOR = $originalColor
    $env:TUKEVEJTSO_PDF_PYTHON = $originalPython
    $resolvedRoot = [IO.Path]::GetFullPath($script:TestRoot)
    $allowedParent = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\'
    if (-not $resolvedRoot.StartsWith($allowedParent, [StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $resolvedRoot) -notlike '.tmp-terminal-*') {
        throw 'Refusing to remove test data outside the test directory.'
    }
    Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
}
Write-Host ("{0} passed; {1} failed." -f $script:Passed, $script:Failures.Count)
if ($script:Failures.Count) { throw ($script:Failures -join "`n") }
