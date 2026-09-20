param(
    [Parameter(Position = 0)][string] $InputPath,
    [Parameter(Position = 1)][string] $OutputPath,
    [ValidateSet('Lossless', 'HighQuality', 'Balanced', 'Small', 'Custom')][string] $Preset = 'Balanced',
    [ValidateRange(20, 95)][int] $Quality,
    [ValidateRange(0, 10000)][int] $MaxImageDimension,
    [switch] $Grayscale, [switch] $RemoveMetadata,
    [switch] $OverwriteOriginal, [switch] $NoBackup,
    [switch] $Menu, [switch] $Json, [switch] $Help
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ui.ps1')
. (Join-Path $PSScriptRoot 'pdf-runtime.ps1')
$script:PdfBackend = Join-Path $PSScriptRoot 'pdf_compress.py'
$script:PdfPython = $null
$script:CompressScrollTop = 0

function Show-CompressPdfDialog {
    param([string] $Initial = '', [switch] $Save)
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = if ($Save) { New-Object System.Windows.Forms.SaveFileDialog } else { New-Object System.Windows.Forms.OpenFileDialog }
    try {
        $dialog.Title = if ($Save) { 'Save compressed PDF as a new file' } else { 'Choose a PDF to compress' }
        $dialog.Filter = 'PDF files (*.pdf)|*.pdf'
        $dialog.RestoreDirectory = $true
        if ($Save) { $dialog.DefaultExt = 'pdf'; $dialog.AddExtension = $true; $dialog.OverwritePrompt = $false }
        else { $dialog.CheckFileExists = $true; $dialog.Multiselect = $false }
        if ($Initial) { $dialog.InitialDirectory = [IO.Path]::GetDirectoryName($Initial); $dialog.FileName = [IO.Path]::GetFileName($Initial) }
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dialog.FileName }
        return $null
    } finally { $dialog.Dispose() }
}

function Resolve-CompressPdfPath {
    param([string] $Path, [switch] $Output)
    $clean = [Environment]::ExpandEnvironmentVariables($Path.Trim().Trim('"'))
    if ($clean.StartsWith('~\') -or $clean.StartsWith('~/')) { $clean = Join-Path $env:USERPROFILE $clean.Substring(2) }
    $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($clean)
    if ([IO.Path]::GetExtension($resolved) -ine '.pdf') { throw 'Choose a file with a .pdf extension.' }
    if (-not $Output -and -not (Test-Path -LiteralPath $resolved -PathType Leaf)) { throw ('Input PDF does not exist: ' + $resolved) }
    return $resolved
}

function Format-CompressPdfSize {
    param([long] $Bytes)
    if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N1} KB' -f ($Bytes / 1KB)) }
    return ('{0} bytes' -f $Bytes)
}

function Set-CompressionPreset {
    param($State, [string] $Name)
    $State.preset = $Name.ToLowerInvariant()
    $State.grayscale = $false
    switch ($State.preset) {
        'lossless' { $State.quality = 88; $State.maxDimension = 0 }
        'highquality' { $State.quality = 95; $State.maxDimension = 0 }
        'small' { $State.quality = 65; $State.maxDimension = 1600 }
        default { $State.quality = 88; $State.maxDimension = 0 }
    }
}

function New-CompressionState {
    param([string] $Source = '')
    return [pscustomobject]@{
        source = $Source; destination = ''; preset = 'balanced'; quality = 88
        maxDimension = 0; grayscale = $false; removeMetadata = $false
        overwrite = $false; keepBackup = $true; info = $null; notice = ''
    }
}

function Get-CompressionOutputPath {
    param($State)
    if ($State.overwrite) { return $State.source }
    if ($State.destination) { return $State.destination }
    $folder = [IO.Path]::GetDirectoryName($State.source)
    $stem = [IO.Path]::GetFileNameWithoutExtension($State.source) + ' - compressed'
    $candidate = Join-Path $folder ($stem + '.pdf')
    $number = 2
    while (Test-Path -LiteralPath $candidate) {
        $candidate = Join-Path $folder ($stem + ' (' + $number + ').pdf')
        $number++
    }
    return $candidate
}

function Set-CompressionSource {
    param($State, [string] $Path)
    $source = Resolve-CompressPdfPath $Path
    $info = Invoke-PdfBackend @{ action = 'inspect'; input = $source }
    $State.source = $source; $State.info = $info
    $State.destination = ''; $State.overwrite = $false; $State.keepBackup = $true
    $State.notice = ''; $script:CompressScrollTop = 0
}

function New-CompressionRequest {
    param($State)
    $request = @{
        action = 'compress'; input = (Resolve-CompressPdfPath $State.source)
        preset = $State.preset; max_dimension = $State.maxDimension
        grayscale = [bool]$State.grayscale; remove_metadata = [bool]$State.removeMetadata
        overwrite = [bool]$State.overwrite; keep_backup = [bool]$State.keepBackup
    }
    if ($State.preset -ne 'lossless') { $request.quality = $State.quality }
    if ($State.destination) { $request.output = Resolve-CompressPdfPath $State.destination -Output }
    return $request
}

function Get-CompressionDimensions {
    try { $width = [Console]::WindowWidth - 1; $height = [Console]::WindowHeight - 1 }
    catch { $width = 99; $height = 29 }
    if ($width -lt 1) { $width = 99 }; if ($height -lt 1) { $height = 29 }
    return @{ Width = $width; Height = $height }
}

function Format-CompressionLine {
    param([string] $Text, [int] $Width, [string] $Color = '#d5d9df', [switch] $Active)
    $safe = $Text -replace '[\x00-\x1f\x7f]', ' '
    $fit = (Format-TuiFit $safe $Width).PadRight($Width)
    $background = if ($Active) { '#253f51' } else { '#202020' }
    if ($Active) { $Color = '#f3f7fa' }
    return Format-TuiAnsiText $fit -Foreground $Color -Background $background
}

function Get-CompressionRows {
    param($State)
    $quality = if ($State.preset -eq 'lossless') { 'Unchanged (lossless)' } else { [string]$State.quality + ' / 100' }
    $resolution = if ($State.maxDimension -eq 0) { 'Original resolution' } else { [string]$State.maxDimension + ' px maximum edge' }
    $mode = if ($State.overwrite) { 'Overwrite original' } elseif ($State.destination) { 'Custom destination' } else { 'New copy (default)' }
    $backup = if (-not $State.overwrite) { 'Not needed for a copy' } elseif ($State.keepBackup) { 'Keep original backup' } else { 'No backup' }
    $presetLabel = switch ($State.preset) { 'highquality' { 'High quality' } 'lossless' { 'Lossless' } 'small' { 'Small' } 'custom' { 'Custom' } default { 'Balanced' } }
    return @(
        @{ Label = 'Preset'; Value = $presetLabel; Detail = 'Left/Right cycles presets. Fine-tuning quality or resolution selects Custom.' },
        @{ Label = 'Image quality'; Value = $quality; Detail = '20-95. Higher keeps more detail. Left/Right adjusts by 5; Enter sets a value.' },
        @{ Label = 'Image resolution'; Value = $resolution; Detail = 'Limit the longest image edge, keeping proportions. 0 keeps original pixels.' },
        @{ Label = 'Image colors'; Value = $(if ($State.grayscale) { 'Grayscale images' } else { 'Keep color' }); Detail = 'Grayscale affects raster images only; vector text and graphics keep their colors.' },
        @{ Label = 'Document metadata'; Value = $(if ($State.removeMetadata) { 'Remove' } else { 'Keep' }); Detail = 'Remove document properties and XMP. Pages, links, forms and attachments stay.' },
        @{ Label = 'Save mode'; Value = $mode; Detail = 'Left/Right switches copy or overwrite. D chooses a new filename or folder.' },
        @{ Label = 'Original backup'; Value = $backup; Detail = 'Overwrite can keep a byte-for-byte copy as <name> - original.pdf.' },
        @{ Label = 'COMPRESS & SAVE'; Value = 'Enter or C'; Detail = 'Compress with these settings, verify the PDF, and save only if it is smaller.' }
    )
}

function Get-CompressionFrame {
    param($State, [int] $Selected = 0)
    $geometry = Get-CompressionDimensions; $width = $geometry.Width; $height = $geometry.Height
    if ($width -lt 38 -or $height -lt 16) {
        return @((Format-CompressionLine 'Compress PDF - enlarge terminal to 39 x 17.' $width '#e7be72'), (Format-CompressionLine 'Q / Esc closes. Settings remain unchanged.' $width))
    }
    $rows = @(Get-CompressionRows $State)
    $visible = [Math]::Min($rows.Count, $height - 13)
    $script:CompressScrollTop = [Math]::Max(0, [Math]::Min($script:CompressScrollTop, $rows.Count - $visible))
    if ($Selected -lt $script:CompressScrollTop) { $script:CompressScrollTop = $Selected }
    elseif ($Selected -ge $script:CompressScrollTop + $visible) { $script:CompressScrollTop = $Selected - $visible + 1 }
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add((Format-CompressionLine ' tukevejtso / COMPRESS PDF' $width '#78c9f2'))
    $lines.Add((Format-CompressionLine ' Tune quality, review the destination, then compress.' $width '#9aa4ae'))
    $lines.Add('')
    $lines.Add((Format-CompressionLine (' File: ' + [IO.Path]::GetFileName($State.source)) $width))
    $summary = if ($State.info) { ' ' + $State.info.pages + ' pages  |  ' + (Format-CompressPdfSize $State.info.bytes) + '  |  Text stays selectable' } else { ' Local PDF compression' }
    $lines.Add((Format-CompressionLine $summary $width '#9aa4ae'))
    $border = [string][char]0x2500
    $first = $script:CompressScrollTop; $last = [Math]::Min($rows.Count, $first + $visible)
    $heading = ' Settings ' + ($first + 1) + '-' + $last + '/' + $rows.Count + ' '
    $lines.Add((Format-CompressionLine (([string][char]0x250c) + $heading + ($border * [Math]::Max(0, $width - $heading.Length - 2)) + [char]0x2510) $width '#606b75'))
    for ($i = $first; $i -lt $last; $i++) {
        $row = $rows[$i]; $marker = if ($Selected -eq $i) { ' > ' } else { '   ' }
        $text = $marker + $row.Label.PadRight(20) + $row.Value
        $body = Format-CompressionLine $text ($width - 2) -Active:($Selected -eq $i)
        $edge = Format-TuiAnsiText ([string][char]0x2502) -Foreground '#606b75' -Background '#202020'
        $lines.Add($edge + $body + $edge)
    }
    $lines.Add((Format-CompressionLine (([string][char]0x2514) + ($border * ($width - 2)) + [char]0x2518) $width '#606b75'))
    $lines.Add((Format-CompressionLine (' ' + $rows[$Selected].Detail) $width '#b6bfc8'))
    $destination = Get-CompressionOutputPath $State
    $saveLabel = if ($State.overwrite) { ' REPLACE: ' } else { ' SAVE: ' }
    $saveColor = if ($State.overwrite) { '#e7be72' } else { '#74d4b5' }
    $lines.Add((Format-CompressionLine ($saveLabel + [IO.Path]::GetFileName($destination)) $width $saveColor))
    $lines.Add((Format-CompressionLine (' Folder: ' + [IO.Path]::GetDirectoryName($destination)) $width '#9aa4ae'))
    $notice = if ($State.notice) { $State.notice } elseif ($State.overwrite) { 'C replaces the original. Backup: ' + $(if ($State.keepBackup) { 'ON' } else { 'OFF' }) } else { 'A separate copy is saved. Existing files get a numbered suffix.' }
    $lines.Add((Format-CompressionLine (' ' + $notice) $width '#e7be72'))
    $help = if ($width -ge 75) { ' Up/Down Select   Left/Right Change   Enter Edit   C Compress' } else { ' Arrows Select/edit  Enter Edit  C Save' }
    $lines.Add((Format-CompressionLine $help $width '#78c9f2'))
    $shortcuts = if ($width -ge 60) { ' F File  P Paste path  D Save as  R Reset  Q/Esc Close' } else { ' F File P Path D Save R Reset Q Quit' }
    $lines.Add((Format-CompressionLine $shortcuts $width '#8ab8c0'))
    return $lines.ToArray()
}

function Read-CompressionKey { return [Console]::ReadKey($true) }
function Read-CompressionValue {
    param([string] $Label, [string] $Current)
    Show-TuiCursor; Clear-Host
    Write-Host $Label -ForegroundColor Cyan
    Write-Host ('Current: ' + $Current + ' | Enter keeps it; :cancel returns.') -ForegroundColor DarkGray
    $value = Read-Host 'Value'
    if ($value -eq ':cancel') { return $null }
    if ([string]::IsNullOrWhiteSpace($value)) { return $Current }
    return $value
}

function Update-CompressionSetting {
    param($State, [int] $Selected, [int] $Direction = 1, [switch] $Edit)
    $State.notice = ''
    switch ($Selected) {
        0 {
            $presets = @('balanced', 'highquality', 'small', 'lossless')
            $index = [Array]::IndexOf($presets, $State.preset)
            Set-CompressionPreset $State $presets[(($index + $Direction + $presets.Count) % $presets.Count)]
        }
        1 {
            $value = if ($Edit) { Read-CompressionValue 'JPEG image quality: 20 to 95' ([string]$State.quality) } else { [Math]::Max(20, [Math]::Min(95, $State.quality + 5 * $Direction)) }
            if ($null -eq $value) { return }
            $number = 0
            if (-not [int]::TryParse([string]$value, [ref]$number) -or $number -lt 20 -or $number -gt 95) { throw 'Image quality must be 20 to 95.' }
            $State.quality = $number; $State.preset = 'custom'
        }
        2 {
            if ($Edit) { $value = Read-CompressionValue 'Maximum image edge: 0 (original), or 128 to 10000 pixels' ([string]$State.maxDimension) }
            else {
                $sizes = @(0, 3200, 2400, 1600, 1200, 800)
                $index = [Array]::IndexOf($sizes, [int]$State.maxDimension)
                $value = $sizes[(($index + $Direction + $sizes.Count) % $sizes.Count)]
            }
            if ($null -eq $value) { return }
            $number = 0
            if (-not [int]::TryParse([string]$value, [ref]$number) -or ($number -ne 0 -and ($number -lt 128 -or $number -gt 10000))) { throw 'Image edge must be 0, or 128 to 10000 pixels.' }
            $State.maxDimension = $number; $State.preset = 'custom'
        }
        3 { $State.grayscale = -not $State.grayscale; if ($State.preset -eq 'lossless') { $State.preset = 'custom' } }
        4 { $State.removeMetadata = -not $State.removeMetadata }
        5 { $State.overwrite = -not $State.overwrite; $State.destination = '' }
        6 { if ($State.overwrite) { $State.keepBackup = -not $State.keepBackup } else { $State.notice = 'Choose Overwrite original to change its backup option.' } }
    }
}

function Select-CompressionDestination {
    param($State)
    $chosen = Show-CompressPdfDialog -Initial (Get-CompressionOutputPath $State) -Save
    if (-not $chosen) { return }
    $resolved = Resolve-CompressPdfPath $chosen -Output
    if (Test-Path -LiteralPath $resolved) { throw 'Choose a new filename. To replace the source, select Overwrite original in Save mode.' }
    $State.destination = $resolved; $State.overwrite = $false
}

function Get-CompressionResultLines {
    param($Result)
    if (-not $Result.saved) { return @($Result.message, 'Try a lower quality or a smaller image edge.') }
    $lines = @(
        ('Before: ' + (Format-CompressPdfSize $Result.before_bytes)),
        ('After:  ' + (Format-CompressPdfSize $Result.after_bytes) + '  |  ' + $Result.reduction_percent + '% smaller'),
        ('Saved:  ' + (Format-CompressPdfSize $Result.saved_bytes)),
        ('Pages: ' + $Result.pages + '  |  Images compressed: ' + $Result.images_compressed),
        ('Resized: ' + $Result.images_resized + '  |  Grayscale: ' + $Result.images_grayscaled),
        ('Output: ' + $Result.output)
    )
    if ($Result.overwritten) { $lines += 'The original PDF was replaced with the verified smaller PDF.' }
    else { $lines += 'The original PDF is unchanged.' }
    if ($Result.backup) { $lines += ('Original backup: ' + $Result.backup) }
    if ($Result.images_skipped -gt 0) { $lines += ('Unsupported images kept unchanged: ' + $Result.images_skipped) }
    return $lines
}

function Show-CompressionResult {
    param($Result)
    Write-TuiPanel -Title $(if ($Result.saved) { 'Compression complete' } else { 'No smaller result' }) -Lines (Get-CompressionResultLines $Result)
}

function Wait-CompressionResult {
    param($Result)
    while ($true) {
        Clear-Host; Show-CompressionResult $Result
        Write-Host 'O Open saved PDF   T Tweak settings   F Another file   Enter/Q/Esc Close' -ForegroundColor Cyan
        $key = Read-CompressionKey
        switch ($key.Key) {
            'O' { if ($Result.output) { Start-Process -FilePath $Result.output } }
            'T' { return 'tweak' }
            'F' { return 'file' }
            'Enter' { return 'close' }
            'Q' { return 'close' }
            'Escape' { return 'close' }
        }
    }
}

function Invoke-CompressPdfMenu {
    param($State = (New-CompressionState))
    if (-not $State.source) {
        $source = Show-CompressPdfDialog
        if (-not $source) { return }
        $State.source = Resolve-CompressPdfPath $source
    }
    $State.info = Invoke-PdfBackend @{ action = 'inspect'; input = $State.source }
    $selected = 0; $initial = $true; $script:CompressScrollTop = 0
    try {
        while ($true) {
            Write-TuiFrame -Lines (Get-CompressionFrame $State $selected) -Initial:$initial
            $initial = $false
            $key = Read-CompressionKey
            if ($key.Key -in @('Q', 'Escape')) { return }
            $geometry = Get-CompressionDimensions
            if ($geometry.Width -lt 38 -or $geometry.Height -lt 16) { continue }
            try {
                switch ($key.Key) {
                    'UpArrow' { $selected = ($selected + 7) % 8 }
                    'DownArrow' { $selected = ($selected + 1) % 8 }
                    'Home' { $selected = 0 }
                    'End' { $selected = 7 }
                    'LeftArrow' { Update-CompressionSetting $State $selected -Direction -1 }
                    'RightArrow' { Update-CompressionSetting $State $selected }
                    'Spacebar' { Update-CompressionSetting $State $selected }
                    'Enter' { if ($selected -ne 7) { Update-CompressionSetting $State $selected -Edit; $initial = $true } }
                    'F' { $path = Show-CompressPdfDialog -Initial $State.source; if ($path) { Set-CompressionSource $State $path }; $initial = $true }
                    'P' { $path = Read-CompressionValue 'Paste a PDF path' $State.source; if ($path) { Set-CompressionSource $State $path }; $initial = $true }
                    'D' { Select-CompressionDestination $State; $initial = $true }
                    'R' { $source = $State.source; $info = $State.info; $State = New-CompressionState $source; $State.info = $info; $selected = 0 }
                }
                if ($key.Key -eq 'C' -or ($key.Key -eq 'Enter' -and $selected -eq 7)) {
                    Show-TuiCursor; Clear-Host
                    Write-TuiPanel -Title 'Compressing PDF' -Lines @([IO.Path]::GetFileName($State.source), 'Optimizing images and page data, then verifying the result...', 'Large PDFs can take a little time.')
                    $result = Invoke-PdfBackend (New-CompressionRequest $State)
                    $action = Wait-CompressionResult $result
                    if ($action -eq 'close') { return }
                    if ($action -eq 'file') {
                        $path = Show-CompressPdfDialog -Initial $State.source
                        if ($path) { Set-CompressionSource $State $path }
                    }
                    $State.info = Invoke-PdfBackend @{ action = 'inspect'; input = $State.source }
                    $State.notice = ''; $initial = $true
                }
            } catch { $State.notice = $_.Exception.Message; $initial = $true }
        }
    } finally { Show-TuiCursor }
}

if ($MyInvocation.InvocationName -eq '.') { return }
if ($Help) {
    Write-Output @'
tk compress-pdf [PDF] [OUTPUT] [options]
Without PDF, open the file picker and terminal settings editor. -Menu opens the
editor for a supplied PDF. With PDF alone, compress immediately with defaults.
-Preset Balanced|HighQuality|Small|Lossless|Custom (default Balanced)
-Quality 20..95          JPEG quality (Balanced 88, HighQuality 95, Small 65)
-MaxImageDimension N    Longest image edge in pixels: 0 original, or 128..10000
                        Small defaults to 1600; other presets keep resolution.
-Grayscale              Convert supported raster images, not vector text/graphics
-RemoveMetadata         Remove document properties and XMP metadata
-OverwriteOriginal      Replace the original only after verification and reduction
-NoBackup               With overwrite, skip the default ' - original.pdf' backup
-Json                   Machine-readable result; requires PDF, cannot use -Menu
The default new copy is '<name> - compressed.pdf'; collisions add (2), (3), etc.
An explicit OUTPUT must not exist; it cannot be combined with -OverwriteOriginal.
Lossless cannot be combined with image quality, resizing, or grayscale settings.
No smaller result means no saved file, no backup, and no overwrite.
Menu: arrows select/change, Enter edit, C compress, F file, P paste, D save as,
R reset, Q/Esc close. The save mode and destination are visible before saving.
Dependencies: Python 3.10+, pypdf 6, Pillow. Install if missing:
py -m pip install "pypdf>=6,<7" Pillow
Aliases: pdf-compress, shrink-pdf
'@
    exit 0
}
try {
    if ($Json) { [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false) }
    if ($Json -and ($Menu -or -not $InputPath)) { throw '-Json requires an input PDF and cannot be used with -Menu.' }
    if ((-not $InputPath -or $Menu) -and [Console]::IsInputRedirected) { throw 'An interactive terminal is required for the editor. Supply a PDF without -Menu for command-line use.' }
    if ($OverwriteOriginal -and $OutputPath) { throw 'Choose either -OverwriteOriginal or an output filename, not both.' }
    if ($Preset -eq 'Lossless' -and ($PSBoundParameters.ContainsKey('Quality') -or $MaxImageDimension -or $Grayscale)) { throw 'Lossless cannot change image quality, resolution, or color. Choose Custom instead.' }
    $state = New-CompressionState
    Set-CompressionPreset $state $Preset
    if ($InputPath) { $state.source = Resolve-CompressPdfPath $InputPath }
    if ($OutputPath) { $state.destination = Resolve-CompressPdfPath $OutputPath -Output }
    if ($PSBoundParameters.ContainsKey('Quality')) { $state.quality = $Quality; $state.preset = 'custom' }
    if ($PSBoundParameters.ContainsKey('MaxImageDimension')) {
        if ($MaxImageDimension -ne 0 -and $MaxImageDimension -lt 128) { throw 'Image edge must be 0 or at least 128 pixels.' }
        $state.maxDimension = $MaxImageDimension; if ($Preset -ne 'Lossless') { $state.preset = 'custom' }
    }
    $state.grayscale = [bool]$Grayscale; $state.removeMetadata = [bool]$RemoveMetadata
    $state.overwrite = [bool]$OverwriteOriginal; $state.keepBackup = -not $NoBackup
    $script:PdfPython = Find-PdfPython -DependencyHint 'PDF compression needs Python 3.10+, pypdf 6, and Pillow. Run: py -m pip install "pypdf>=6,<7" Pillow. Or set TUKEVEJTSO_PDF_PYTHON.'
    if (-not $InputPath -or $Menu) { Invoke-CompressPdfMenu $state }
    else {
        if (-not $Json) { Write-Host 'Compressing PDF...' -ForegroundColor Cyan }
        $result = Invoke-PdfBackend (New-CompressionRequest $state)
        if ($Json) { $result | ConvertTo-Json -Depth 8 } else { Show-CompressionResult $result }
    }
} catch {
    if ($Json) { @{ ok = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress }
    else { Write-Host ('PDF compression: ' + $_.Exception.Message) -ForegroundColor Red }
    exit 1
} finally { Show-TuiCursor }
