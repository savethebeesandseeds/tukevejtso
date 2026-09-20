param(
    [Parameter(Position = 0)][string] $Folder,
    [switch] $Recursive,
    [switch] $NoMenu,
    [switch] $Help
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ui.ps1')
. (Join-Path $PSScriptRoot 'pdf-tree.ps1')
$script:PdfBackend = Join-Path $PSScriptRoot 'pdf_join.py'
$script:PdfPython = $null
$script:PdfStatePath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'tukevejtso\pdf-join.json'
$script:PdfNotice = ''

. (Join-Path $PSScriptRoot 'pdf-runtime.ps1')

function Resolve-PdfFolder {
    param([string] $Path)
    $clean = [Environment]::ExpandEnvironmentVariables($Path.Trim().Trim('"'))
    if ($clean -eq '~') { $clean = $env:USERPROFILE }
    elseif ($clean.StartsWith('~\') -or $clean.StartsWith('~/')) { $clean = Join-Path $env:USERPROFILE $clean.Substring(2) }
    $item = Get-Item -LiteralPath $clean -Force
    if (-not $item.PSIsContainer -or $item.PSProvider.Name -ne 'FileSystem') { throw 'Choose a filesystem folder.' }
    return $item.FullName
}

function Read-PdfState {
    $state = [pscustomobject]@{ folder = ''; recursive = $true; selected = @(); output = ''; lastOutput = '' }
    if (Test-Path -LiteralPath $script:PdfStatePath -PathType Leaf) {
        try {
            $saved = Get-Content -LiteralPath $script:PdfStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($saved.folder -is [string]) { $state.folder = $saved.folder }
            # Upgrade older flat-list defaults once, then remember explicit toggles.
            if ($saved.version -eq 2 -and $saved.recursive -is [bool]) { $state.recursive = $saved.recursive }
            $state.selected = @($saved.selected | Where-Object { $_ -is [string] })
            if ($saved.lastOutput -is [string]) { $state.lastOutput = $saved.lastOutput }
        } catch { $script:PdfNotice = 'Saved settings could not be read; starting with defaults.' }
    }
    return $state
}

function Save-PdfState {
    param($State)
    $temp = $null
    try {
        $dir = Split-Path -Parent $script:PdfStatePath
        [void][IO.Directory]::CreateDirectory($dir)
        $temp = Join-Path $dir ([IO.Path]::GetRandomFileName())
        $saved = [ordered]@{ version = 2; folder = $State.folder; recursive = $State.recursive; selected = @($State.selected); lastOutput = $State.lastOutput }
        [IO.File]::WriteAllText($temp, ($saved | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
        if ([IO.File]::Exists($script:PdfStatePath)) { [IO.File]::Replace($temp, $script:PdfStatePath, [NullString]::Value) }
        else { [IO.File]::Move($temp, $script:PdfStatePath) }
    } catch { $script:PdfNotice = 'Could not save settings: ' + $_.Exception.Message }
    finally { if ($temp -and [IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}

function Get-PdfOutputPath {
    param([string] $Directory, [string[]] $Selected)
    if (-not $Selected -or $Selected.Count -eq 0) { return '' }
    $parts = New-Object 'System.Collections.Generic.List[string]'
    for ($index = 0; $index -lt $Selected.Count; $index++) {
        $stem = [IO.Path]::GetFileNameWithoutExtension($Selected[$index]).Trim()
        if ($index -gt 0) {
            $words = @($stem -split '[\s_-]+' | Where-Object { $_ })
            if ($words.Count) { $stem = $words[0] }
        }
        if (-not $stem) { $stem = 'PDF' }
        $parts.Add($stem)
    }
    $baseName = $parts -join ' - '
    $number = 2
    $name = $baseName + '.pdf'
    while ($true) {
        $path = Join-Path $Directory $name
        # Leave headroom for legacy Windows PowerShell filesystem operations.
        if ($path.Length -gt 240) {
            throw 'The combined PDF filename is too long. Shorten the source filenames or select fewer files.'
        }
        if (-not (Test-Path -LiteralPath $path)) { break }
        $name = '{0} ({1}).pdf' -f $baseName, $number
        $number++
    }
    return $path
}

function Update-PdfOutputPath {
    param($State)
    try { $State.output = Get-PdfOutputPath -Directory $State.folder -Selected $State.selected }
    catch { $State.output = ''; $script:PdfNotice = $_.Exception.Message }
}

function Get-PdfPageSize {
    param([int] $Overhead = 15)
    $height = [Console]::WindowHeight
    if ($height -le 0) { $height = 25 }
    return [Math]::Max(1, $height - $Overhead)
}

function Read-PdfKey {
    return [Console]::ReadKey($true)
}

function Get-PdfLineWidth {
    $width = [Console]::WindowWidth - 1
    if ($width -lt 1) { $width = 99 }
    return $width
}

function Format-PdfLine {
    param([string] $Text, [string] $Color = '#d7d7d7', [switch] $Active)
    $width = Get-PdfLineWidth
    $safe = $Text -replace '[\x00-\x1f\x7f]', ' '
    $fit = Format-TuiFit -Text $safe -Width $width
    if ($Active) { return Format-TuiAnsiText -Text $fit.PadRight($width) -Foreground '#ffffff' -Background '#236f9f' }
    return Format-TuiAnsiText -Text $fit -Foreground $Color
}

function Format-PdfPanelRow {
    param([string] $Text = '', [string] $Color = '#d7d7d7', [switch] $Active)
    $insideWidth = [Math]::Max(1, (Get-PdfLineWidth) - 3)
    $safe = $Text -replace '[\x00-\x1f\x7f]', ' '
    $content = (Format-TuiFit -Text $safe -Width ($insideWidth - 1)).PadRight($insideWidth)
    $edge = Format-TuiAnsiText -Text ([string][char]0x2502) -Foreground '#69737b' -Background '#202020'
    $background = if ($Active) { '#236f9f' } else { '#202020' }
    if ($Active) { $Color = '#ffffff' }
    return ' ' + $edge + (Format-TuiAnsiText -Text $content -Foreground $Color -Background $background) + $edge
}

function Format-PdfPanelBorder {
    param([switch] $Bottom, [switch] $More)
    $insideWidth = [Math]::Max(1, (Get-PdfLineWidth) - 3)
    $left = if ($Bottom) { [char]0x2514 } else { [char]0x250c }
    $right = if ($Bottom) { [char]0x2518 } else { [char]0x2510 }
    $rule = [string][char]0x2500
    $label = if ($Bottom) { '' } else { ' Files ' }
    $indicator = if ($More) {
        if ($Bottom) { ' ' + [char]0x2193 + ' More below ' }
        else { ' ' + [char]0x2191 + ' More above ' }
    } else { '' }
    # Keep both corners intact even in a narrow terminal.
    $indicator = Format-TuiFit -Text $indicator -Width ([Math]::Max(0, $insideWidth - 2))
    $label = Format-TuiFit -Text $label -Width ([Math]::Max(0, $insideWidth - $indicator.Length - 2))
    $fill = $rule * [Math]::Max(0, $insideWidth - $label.Length - $indicator.Length - 1)
    $prefix = Format-TuiAnsiText -Text ($left + $label + $fill) -Foreground '#69737b' -Background '#202020'
    $badge = if ($indicator) { Format-TuiAnsiText -Text $indicator -Foreground '#8eeaff' -Background '#34454a' -Bold } else { '' }
    $suffix = Format-TuiAnsiText -Text ($rule + $right) -Foreground '#69737b' -Background '#202020'
    return ' ' + $prefix + $badge + $suffix
}

function Read-PdfText {
    param([string] $Label, [string] $Current = '')
    Show-TuiCursor
    Clear-Host
    Write-Host $Label -ForegroundColor Cyan
    if ($Current) { Write-Host $Current -ForegroundColor Gray }
    Write-Host 'Enter keeps the current value; :cancel cancels.' -ForegroundColor DarkGray
    $value = Read-Host 'Value'
    if ($value -eq ':cancel') { return $null }
    if ([string]::IsNullOrWhiteSpace($value)) { return $Current }
    return $value
}

function Show-PdfFolderDialog {
    param([string] $Initial = '')
    if (-not ('Tukevejtso.PdfFolderPicker' -as [type])) {
        Add-Type -Path (Join-Path $PSScriptRoot 'pdf-folder-picker.cs')
    }
    return [Tukevejtso.PdfFolderPicker]::Show($Initial)
}

function Select-PdfFolder {
    param([string] $Initial = '')
    Show-TuiCursor
    Write-Host 'Choose a folder in the Windows dialog. Cancel returns without changes.' -ForegroundColor Cyan
    $start = if ($Initial -and (Test-Path -LiteralPath $Initial -PathType Container)) { $Initial } else { '' }
    $chosen = Show-PdfFolderDialog -Initial $start
    if ([string]::IsNullOrWhiteSpace($chosen)) { return $null }
    return (Resolve-PdfFolder $chosen)
}

function Initialize-PdfSession {
    param($State, [string] $Folder, [switch] $NoMenu, [switch] $Recursive)
    if ($Folder) {
        $chosen = Resolve-PdfFolder $Folder
    } elseif ($NoMenu) {
        if (-not $State.folder) { throw 'Specify a folder with -NoMenu; no folder has been selected yet.' }
        $chosen = Resolve-PdfFolder $State.folder
    } else {
        $chosen = Select-PdfFolder -Initial $State.folder
        if (-not $chosen) { return $null }
    }
    if ($chosen -ne $State.folder) {
        $State.selected = @(); $State.output = ''; $State.lastOutput = ''
    }
    $State.folder = $chosen
    if ($PSBoundParameters.ContainsKey('Recursive')) { $State.recursive = [bool]$Recursive }
    Update-PdfOutputPath $State
    return $State
}

function Update-PdfFiles {
    param($State)
    $result = Invoke-PdfBackend @{ action = 'scan'; folder = $State.folder; recursive = $State.recursive; exclude = @(@($State.lastOutput) | Where-Object { $_ }) }
    $State.folder = $result.folder
    $files = @($result.files)
    $present = @{}
    foreach ($file in $files) { $present[$file.relative] = $file.relative }
    $before = @($State.selected).Count
    $State.selected = @($State.selected | Where-Object { $present.ContainsKey($_) } | ForEach-Object { $present[$_] } | Select-Object -Unique)
    $messages = @($result.warnings)
    if ($before -gt $State.selected.Count) { $messages += 'Missing or excluded PDFs were removed from the selection.' }
    if ($messages.Count) { $script:PdfNotice = $messages -join ' | ' }
    Update-PdfOutputPath $State
    return ,$files
}

function Invoke-PdfJoinMenu {
    param($State)
    $files = Update-PdfFiles $State
    Save-PdfState $State
    $cursor = 0
    $filter = ''
    $orderedView = $false
    $review = $false
    $initial = $true
    $treeRows = $null
    $treeFiles = $null
    $treeFilter = $null
    $scrollTop = 0
    while ($true) {
        if ($orderedView) {
            $lookup = @{}
            foreach ($file in $files) { $lookup[$file.relative] = $file }
            $visible = @($State.selected | ForEach-Object { $lookup[$_] } | Where-Object { $null -ne $_ })
        } else { $visible = @($files) }
        if ($filter) { $visible = @($visible | Where-Object { $_.relative.IndexOf($filter, [StringComparison]::OrdinalIgnoreCase) -ge 0 }) }
        $size = Get-PdfPageSize
        $cursor = [Math]::Max(0, [Math]::Min($cursor, $visible.Count - 1))
        if ($orderedView) {
            $rows = @(for ($fileIndex = 0; $fileIndex -lt $visible.Count; $fileIndex++) {
                [pscustomobject]@{ FileIndex = $fileIndex; IsFolder = $false; Prefix = ''; Label = $visible[$fileIndex].relative }
            })
        } else {
            if ($null -eq $treeRows -or -not [object]::ReferenceEquals($treeFiles, $files) -or $treeFilter -cne $filter) {
                $treeRows = @(Get-PdfTreeRows -Files $visible)
                $treeFiles = $files
                $treeFilter = $filter
            }
            $rows = $treeRows
        }
        $activeRow = 0
        for ($rowIndex = 0; $rowIndex -lt $rows.Count; $rowIndex++) {
            if ($rows[$rowIndex].FileIndex -eq $cursor) { $activeRow = $rowIndex; break }
        }
        # Keep the viewport stable until focus crosses an edge; never snap to pages.
        $scrollTop = [Math]::Max(0, [Math]::Min($scrollTop, [Math]::Max(0, $rows.Count - $size)))
        if ($activeRow -lt $scrollTop) { $scrollTop = $activeRow }
        elseif ($activeRow -ge $scrollTop + $size) { $scrollTop = $activeRow - $size + 1 }
        $start = $scrollTop
        $lines = New-Object 'System.Collections.Generic.List[string]'
        $title = if ($review) { 'REVIEW / Enter to join' } elseif ($orderedView) { 'Merge order' } else { 'PDF tree' }
        $lines.Add((Format-PdfLine (' tukevejtso / PDF JOIN / ' + $title) '#5dd9e8'))
        $lines.Add((Format-PdfLine (' Folder: ' + $State.folder)))
        $scope = if ($State.recursive) { 'Folder + all subfolders' } else { 'This folder only' }
        $lines.Add((Format-PdfLine (' Scope: ' + $scope + ' | ' + $files.Count + ' PDFs') '#777777'))
        $outputLabel = if ($State.output) { [IO.Path]::GetFileName($State.output) } elseif ($State.selected.Count) { '(filename unavailable; adjust selection)' } else { '(select PDFs to generate the filename)' }
        $lines.Add((Format-PdfLine (' Output: ' + $outputLabel)))
        $lines.Add((Format-PdfLine (' Search: ' + $(if ($filter) { $filter } else { '(all)' }) + ' | ' + $State.selected.Count + ' selected') '#37d99e'))
        $lines.Add((Format-PdfPanelBorder -More:($start -gt 0)))
        if (-not $visible.Count) { $lines.Add((Format-PdfPanelRow ' No PDFs here. Change folder/scope/search or select files first.' '#ffd45a')) }
        for ($i = $start; $i -lt [Math]::Min($rows.Count, $start + $size); $i++) {
            $row = $rows[$i]
            if ($row.IsFolder) {
                $lines.Add((Format-PdfPanelRow ('          ' + $row.Prefix + $row.Label) '#5dd9e8'))
                continue
            }
            $file = $visible[$row.FileIndex]
            $order = [Array]::IndexOf([object[]]$State.selected, $file.relative)
            $mark = if ($order -ge 0) { '[x] {0,3}' -f ($order + 1) } else { '[ ]    ' }
            $lines.Add((Format-PdfPanelRow (' {0}  {1}{2}' -f $mark, $row.Prefix, $row.Label) -Active:($row.FileIndex -eq $cursor)))
        }
        $shownRows = [Math]::Max(1, [Math]::Min($size, $rows.Count - $start))
        for ($blank = $shownRows; $blank -lt $size; $blank++) { $lines.Add((Format-PdfPanelRow)) }
        $lines.Add((Format-PdfPanelBorder -Bottom -More:($start + $size -lt $rows.Count)))
        $detail = if ($visible.Count) { '{0} | {1:N1} KB' -f $visible[$cursor].relative, ($visible[$cursor].size / 1KB) } else { '' }
        $lines.Add((Format-PdfLine (' ' + $detail) '#777777'))
        $lines.Add((Format-PdfLine (' Rows {0}-{1} of {2} | {3} PDFs | Numbers = merge order' -f [Math]::Min($start + 1, $rows.Count), [Math]::Min($rows.Count, $start + $size), $rows.Count, $visible.Count) '#777777'))
        if ($review) {
            $lines.Add((Format-PdfLine ' Up/Down Scroll | Enter JOIN | Esc Back' '#5dd9e8'))
            $lines.Add((Format-PdfLine ' Every selected PDF will be appended in the numbered order.' '#777777'))
            $lines.Add('')
        } else {
            $lines.Add((Format-PdfLine ' Up/Down Scroll | Space Toggle | A All | N None | Tab Order' '#5dd9e8'))
            $lines.Add((Format-PdfLine ' +/- Reorder | / Search | R Subfolders | F5 Refresh' '#5dd9e8'))
            $lines.Add((Format-PdfLine ' F Windows picker | P Paste folder | Enter Review | Q Quit' '#5dd9e8'))
        }
        $lines.Add((Format-PdfLine (' ' + $script:PdfNotice) '#ffd45a'))
        Write-TuiFrame -Lines $lines.ToArray() -Initial:$initial
        $initial = $false
        $key = Read-PdfKey
        $script:PdfNotice = ''
        try {
            if ($key.Key -in @('UpArrow', 'DownArrow', 'PageUp', 'PageDown', 'Home', 'End')) {
                switch ($key.Key) {
                    { $_ -in @('UpArrow', 'PageUp') } { $cursor = [Math]::Max(0, $cursor - 1) }
                    { $_ -in @('DownArrow', 'PageDown') } { $cursor++ }
                    'Home' { $cursor = 0; $scrollTop = 0 }
                    'End' { $cursor = [Math]::Max(0, $visible.Count - 1) }
                }
                continue
            }
            if ($key.Key -eq 'Escape' -or $key.Key -eq 'Q') {
                if ($review) { $review = $false; continue }
                Save-PdfState $State
                return
            }
            if ($review) {
                if ($key.Key -eq 'Enter') {
                    Show-TuiCursor
                    Clear-Host
                    Write-Host ('Joining {0} PDFs...' -f $State.selected.Count) -ForegroundColor Cyan
                    $paths = @($State.selected | ForEach-Object { Join-Path $State.folder $_ })
                    $result = Invoke-PdfBackend @{ action = 'merge'; paths = $paths; output = $State.output }
                    $State.lastOutput = $result.output
                    Update-PdfOutputPath $State
                    Save-PdfState $State
                    Write-Host ('Created {0} pages from {1} PDFs.' -f $result.pages, $result.files) -ForegroundColor Green
                    Write-Host $result.output
                    Write-Host 'Press any key to close' -ForegroundColor DarkGray
                    [void](Read-PdfKey)
                    return
                }
                continue
            }
            switch ($key.Key) {
                'Spacebar' {
                    if ($visible.Count) {
                        $path = $visible[$cursor].relative
                        if ($State.selected -contains $path) { $State.selected = @($State.selected | Where-Object { $_ -ne $path }) }
                        else { $State.selected = @($State.selected) + $path }
                    }
                }
                'A' { foreach ($file in $visible) { if ($State.selected -notcontains $file.relative) { $State.selected = @($State.selected) + $file.relative } } }
                'N' { $remove = @($visible | ForEach-Object { $_.relative }); $State.selected = @($State.selected | Where-Object { $remove -notcontains $_ }) }
                'Tab' { $orderedView = -not $orderedView; $cursor = 0; $scrollTop = 0 }
                'R' { $State.recursive = -not $State.recursive; $files = Update-PdfFiles $State; $cursor = 0; $scrollTop = 0 }
                'F5' { $files = Update-PdfFiles $State }
                { $_ -in @('F', 'P') } {
                    if ($key.Key -eq 'F') { $chosen = Select-PdfFolder $State.folder }
                    else { $typed = Read-PdfText 'Folder path' $State.folder; $chosen = if ($null -ne $typed) { Resolve-PdfFolder $typed } else { $null } }
                    $initial = $true
                    if ($chosen -and $chosen -ne $State.folder) {
                        $State.folder = $chosen; $State.selected = @(); $State.lastOutput = ''; $State.output = ''
                        $files = Update-PdfFiles $State; $cursor = 0; $scrollTop = 0; $filter = ''; $orderedView = $false
                    }
                }
                'Enter' {
                    if (-not $State.selected.Count) { throw 'Select at least one PDF with Space or A.' }
                    Update-PdfOutputPath $State
                    if (-not $State.output) { throw $script:PdfNotice }
                    $review = $true; $orderedView = $true; $filter = ''; $cursor = 0; $scrollTop = 0
                }
                default {
                    if ($key.KeyChar -eq '/') {
                        $newFilter = Read-PdfText 'Search relative PDF filenames (use * to clear)' $filter
                        if ($null -ne $newFilter) { $filter = if ($newFilter -eq '*') { '' } else { $newFilter }; $cursor = 0; $scrollTop = 0 }
                        $initial = $true
                    }
                    elseif ($key.KeyChar -in @('+', '-', '=')) {
                        if ($visible.Count) {
                            $index = [Array]::IndexOf([object[]]$State.selected, $visible[$cursor].relative)
                            $delta = if ($key.KeyChar -eq '-') { -1 } else { 1 }
                            $next = $index + $delta
                            if ($index -ge 0 -and $next -ge 0 -and $next -lt $State.selected.Count) {
                                $temp = $State.selected[$index]; $State.selected[$index] = $State.selected[$next]; $State.selected[$next] = $temp
                                if ($orderedView -and -not $filter) { $cursor = $next }
                            } else { $script:PdfNotice = 'Select this PDF first; - moves earlier and + moves later.' }
                        }
                    }
                }
            }
            Update-PdfOutputPath $State
            Save-PdfState $State
        } catch { $script:PdfNotice = $_.Exception.Message; Update-PdfOutputPath $State; $review = $false; $initial = $true }
    }
}

if ($MyInvocation.InvocationName -eq '.') { return }
if ($Help) {
    Write-Output @'
tk join-pdfs [FOLDER] [-Recursive] [-NoMenu]
Choose a folder in the Windows dialog, select PDFs, then review and join.
Without FOLDER, the dialog opens every time. The previous folder is only its starting view.
PDFs in subfolders are included by default and displayed as a folder tree.
Folder rows show structure; arrow keys and Space navigate and select PDFs only.
Up/Down scroll continuously. Arrows on the file panel's borders indicate more content.
The output goes in the search folder. Its name is the first selected PDF's full
stem plus the first word of each later filename, in merge order, joined by ' - '.
Folder, recursive scope, and selected files are remembered locally.
-NoMenu prints the discovered PDF list as JSON and never merges or saves settings.
Use F/P for folders, R for subfolders, Space/A/N to select, Tab and +/- for order,
/ to search, Enter to review, then Enter to join. Q/Esc exits.
Dependencies: Python 3.10+ and pypdf 6; py -m pip install "pypdf>=6,<7"
'@
    exit 0
}
try {
    if (-not $NoMenu -and [Console]::IsInputRedirected) {
        throw 'An interactive terminal is required. Use -NoMenu to list PDFs as JSON.'
    }
    $options = @{ State = (Read-PdfState); Folder = $Folder; NoMenu = $NoMenu }
    if ($PSBoundParameters.ContainsKey('Recursive')) { $options.Recursive = $Recursive }
    $state = Initialize-PdfSession @options
    if ($null -eq $state) { exit 0 }
    $script:PdfPython = Find-PdfPython
    if ($NoMenu) {
        Invoke-PdfBackend @{ action = 'scan'; folder = $state.folder; recursive = $state.recursive; exclude = @(@($state.lastOutput) | Where-Object { $_ }) } | ConvertTo-Json -Depth 8
    } else {
        Invoke-PdfJoinMenu $state
    }
} catch {
    Write-Host ('PDF join: ' + $_.Exception.Message) -ForegroundColor Red
    exit 1
} finally { Show-TuiCursor }
