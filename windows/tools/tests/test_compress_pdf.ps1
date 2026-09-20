param([string] $Python, [string] $FrameOutput)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\compress-pdf.ps1')
if (-not $Python) { $Python = Find-PdfPython }
$script:PdfPython = $Python
$script:Passed = 0
$script:Failures = New-Object 'System.Collections.Generic.List[string]'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('pdf-settings-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$script:Source = Join-Path $testRoot 'Application [1].pdf'
[IO.File]::WriteAllText($script:Source, 'controller fixture')
$script:FrameWidth = 99; $script:FrameHeight = 29
function Get-CompressionDimensions { return @{ Width = $script:FrameWidth; Height = $script:FrameHeight } }
function Assert-True([bool] $Condition, [string] $Message) { if (-not $Condition) { throw $Message } }
function Test-Case([string] $Name, [scriptblock] $Body) {
    try { & $Body; $script:Passed++; Write-Host "PASS $Name" }
    catch { $script:Failures.Add("$Name : $($_.Exception.Message)"); Write-Host "FAIL $Name : $($_.Exception.Message)" }
}
function Set-Keys([string[]] $Keys) {
    $script:Keys = New-Object 'System.Collections.Generic.Queue[string]'
    foreach ($key in $Keys) { $script:Keys.Enqueue($key) }
    $script:Frames = New-Object 'System.Collections.Generic.List[string]'
    $script:Requests = New-Object 'System.Collections.Generic.List[object]'
}
function Read-CompressionKey {
    if (-not $script:Keys.Count) { throw 'Scripted keys exhausted.' }
    return [pscustomobject]@{ Key = $script:Keys.Dequeue() }
}
function Write-TuiFrame([string[]] $Lines, [switch] $Initial) { $script:Frames.Add(($Lines -join [Environment]::NewLine)) }
function Write-TuiPanel { param($Title, $Lines) }
function Clear-Host { }
try {
    Test-Case 'Windows PowerShell 5.1 and compression runtime' {
        Assert-True ($PSVersionTable.PSVersion.Major -eq 5) 'Use powershell.exe.'
        $result = Invoke-PdfBackend @{ action = 'probe' }
        Assert-True ($result.ok -and $result.version.StartsWith('6.') -and $result.pillow) 'Dependencies missing.'
    }
    Test-Case 'Invalid source returns actionable backend error' {
        $message = ''
        try { [void](Invoke-PdfBackend @{ action = 'compress'; input = 'relative.pdf' }) } catch { $message = $_.Exception.Message }
        Assert-True ($message -like '*absolute file path*') 'Expected path validation.'
    }
    Test-Case 'Copy is default with the requested filename and collision suffix' {
        $state = New-CompressionState $script:Source
        $expected = Join-Path $testRoot 'Application [1] - compressed.pdf'
        Assert-True (-not $state.overwrite -and (Get-CompressionOutputPath $state) -eq $expected) 'Incorrect default.'
        [IO.File]::WriteAllText($expected, 'existing PDF')
        Assert-True ((Get-CompressionOutputPath $state) -eq (Join-Path $testRoot 'Application [1] - compressed (2).pdf')) 'Collision was not numbered.'
    }
    Test-Case 'Presets expose quality and image resolution' {
        $state = New-CompressionState
        Set-CompressionPreset $state 'HighQuality'
        Assert-True ($state.quality -eq 95 -and $state.maxDimension -eq 0) 'High quality preset.'
        Set-CompressionPreset $state 'Small'
        Assert-True ($state.quality -eq 65 -and $state.maxDimension -eq 1600) 'Small preset.'
        $state.grayscale = $true
        Set-CompressionPreset $state 'Lossless'
        Assert-True (-not $state.grayscale -and $state.maxDimension -eq 0) 'Lossless must reset image changes.'
    }
    Test-Case 'Quality keys clamp to range and leave lossless for custom' {
        $state = New-CompressionState
        Set-CompressionPreset $state 'Lossless'
        Update-CompressionSetting $state 1
        Assert-True ($state.preset -eq 'custom' -and $state.quality -eq 93) 'Quality did not change.'
        Update-CompressionSetting $state 1
        Assert-True ($state.quality -eq 95) 'Quality exceeded 95.'
        $state.quality = 20
        Update-CompressionSetting $state 1 -Direction -1
        Assert-True ($state.quality -eq 20) 'Quality fell below 20.'
    }
    Test-Case 'Custom numeric edits validate before changing state' {
        $state = New-CompressionState
        function Read-CompressionValue { return '2048' }
        Update-CompressionSetting $state 2 -Edit
        Assert-True ($state.maxDimension -eq 2048 -and $state.preset -eq 'custom') 'Custom edge not applied.'
        function Read-CompressionValue { return '12' }
        $message = ''
        try { Update-CompressionSetting $state 2 -Edit } catch { $message = $_.Exception.Message }
        Assert-True ($message -and $state.maxDimension -eq 2048) 'Invalid edit changed state.'
        function Read-CompressionValue { return $null }
        Update-CompressionSetting $state 1 -Edit
        Assert-True ($state.quality -eq 88) 'Cancel changed quality.'
    }
    Test-Case 'Overwrite is explicit, previewed, and can disable its backup' {
        $state = New-CompressionState $script:Source
        Update-CompressionSetting $state 5
        Assert-True ($state.overwrite -and (Get-CompressionOutputPath $state) -eq $script:Source) 'Overwrite path mismatch.'
        Update-CompressionSetting $state 6
        $request = New-CompressionRequest $state
        Assert-True ($request.overwrite -and -not $request.keep_backup -and -not $request.ContainsKey('output')) 'Wrong overwrite request.'
        Update-CompressionSetting $state 5
        Assert-True (-not $state.overwrite) 'Could not return to copy.'
    }
    Test-Case 'Custom destination disables overwrite and cancellation preserves state' {
        $state = New-CompressionState $script:Source
        $state.overwrite = $true
        function Show-CompressPdfDialog { return (Join-Path $testRoot 'custom result.pdf') }
        Select-CompressionDestination $state
        Assert-True (-not $state.overwrite -and $state.destination.EndsWith('custom result.pdf')) 'Save-as did not select a copy.'
        function Show-CompressPdfDialog { return $null }
        Select-CompressionDestination $state
        Assert-True ($state.destination.EndsWith('custom result.pdf')) 'Cancel changed the destination.'
    }
    Test-Case 'Save-as refuses an existing source or other file' {
        $state = New-CompressionState $script:Source
        function Show-CompressPdfDialog { return $script:Source }
        $message = ''
        try { Select-CompressionDestination $state } catch { $message = $_.Exception.Message }
        Assert-True ($message -like '*Overwrite original*' -and -not $state.overwrite) 'Existing file was implicitly selected.'
    }
    Test-Case 'Selecting another PDF resets overwrite but preserves quality' {
        $state = New-CompressionState $script:Source
        $state.overwrite = $true; $state.keepBackup = $false; $state.quality = 72
        function Invoke-PdfBackend { return [pscustomobject]@{ bytes = 100; pages = 2 } }
        Set-CompressionSource $state $script:Source
        Assert-True (-not $state.overwrite -and $state.keepBackup -and $state.quality -eq 72) 'New file inherited overwrite.'
    }
    Test-Case 'Settings fit normal and small terminals with visible selection' {
        $state = New-CompressionState $script:Source
        foreach ($size in @(@(99, 29), @(79, 23), @(47, 16))) {
            $script:FrameWidth = $size[0]; $script:FrameHeight = $size[1]
            foreach ($selected in @(0, 5, 7)) {
                $lines = @(Get-CompressionFrame $state $selected)
                Assert-True ($lines.Count -le $script:FrameHeight) 'Frame exceeds terminal height.'
                foreach ($line in $lines) { Assert-True ((Remove-TuiAnsi $line).Length -le $script:FrameWidth) 'Frame exceeds terminal width.' }
                Assert-True (($lines -join '').Contains(' > ')) 'Selection was scrolled out of view.'
            }
        }
        $script:FrameWidth = 99; $script:FrameHeight = 29
    }
    Test-Case 'Frame clearly identifies replacement and backup status' {
        $state = New-CompressionState $script:Source
        $state.overwrite = $true
        $text = (Get-CompressionFrame $state 5) -join ''
        Assert-True ($text.Contains('REPLACE:') -and $text.Contains('Backup: ON')) 'Overwrite is not visible.'
    }
    Test-Case 'Picker cancellation does not inspect or compress' {
        function Show-CompressPdfDialog { return $null }
        function Invoke-PdfBackend { throw 'Must not run after cancel.' }
        Invoke-CompressPdfMenu
    }
    Test-Case 'Closing settings never compresses' {
        Set-Keys @('Q')
        function Invoke-PdfBackend { param($Request) Assert-True ($Request.action -eq 'inspect') 'Unexpected compression.'; return [pscustomobject]@{ bytes = 100; pages = 2 } }
        Invoke-CompressPdfMenu (New-CompressionState $script:Source)
    }
    Test-Case 'Keyboard workflow submits the visible overwrite and custom settings' {
        Set-Keys @('DownArrow','LeftArrow','DownArrow','RightArrow','DownArrow','RightArrow','DownArrow','RightArrow','DownArrow','RightArrow','C')
        function Invoke-PdfBackend {
            param($Request)
            if ($Request.action -eq 'compress') { $script:Requests.Add($Request); return [pscustomobject]@{ saved = $true } }
            return [pscustomobject]@{ bytes = 100; pages = 2 }
        }
        function Wait-CompressionResult { return 'close' }
        Invoke-CompressPdfMenu (New-CompressionState $script:Source)
        $request = $script:Requests[0]
        Assert-True ($script:Requests.Count -eq 1 -and $request.quality -eq 83 -and $request.max_dimension -eq 3200) 'Custom settings not submitted.'
        Assert-True ($request.grayscale -and $request.remove_metadata -and $request.overwrite -and $request.keep_backup) 'Flags not submitted.'
    }
    Test-Case 'Backend failure stays in editor and displays the error' {
        Set-Keys @('C','Q')
        function Invoke-PdfBackend {
            param($Request)
            if ($Request.action -eq 'compress') { throw 'Test: source changed during compression.' }
            return [pscustomobject]@{ bytes = 100; pages = 2 }
        }
        Invoke-CompressPdfMenu (New-CompressionState $script:Source)
        Assert-True (($script:Frames -join '').Contains('source changed')) 'Failure was not displayed.'
    }
    if ($FrameOutput) {
        function Test-TuiAnsi { return $true }
        $state = New-CompressionState 'C:\Documents\Application.pdf'
        $state.info = [pscustomobject]@{ pages = 13; bytes = 5531511 }
        $frames = @()
        $script:FrameWidth = 99; $script:FrameHeight = 29
        $frames += @{ name = 'default'; width = 99; lines = @(Get-CompressionFrame $state 1) }
        $state.overwrite = $true
        $frames += @{ name = 'overwrite'; width = 99; lines = @(Get-CompressionFrame $state 5) }
        $script:FrameWidth = 47; $script:FrameHeight = 16
        $frames += @{ name = 'compact'; width = 47; lines = @(Get-CompressionFrame $state 7) }
        $frames | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $FrameOutput -Encoding UTF8
    }
} finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $expectedPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\pdf-settings-'
    if (-not $resolved.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected test cleanup path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-Host "$script:Passed passed; $($script:Failures.Count) failed."
if ($script:Failures.Count) { exit 1 }

