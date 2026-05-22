$ErrorActionPreference = "SilentlyContinue"

. (Join-Path $PSScriptRoot "ui.ps1")

$extensions = @(".exe", ".msi", ".dll", ".scr", ".bat", ".cmd", ".ps1", ".vbs", ".js")
$roots = @(
    @{ Name = "Downloads"; Path = Join-Path $env:USERPROFILE "Downloads" },
    @{ Name = "Temp"; Path = $env:TEMP },
    @{ Name = "Local AppData"; Path = $env:LOCALAPPDATA },
    @{ Name = "Roaming AppData"; Path = $env:APPDATA }
)

function Get-TrustStatus {
    param([System.IO.FileInfo] $File)

    if ($File.Extension.ToLowerInvariant() -notin @(".exe", ".msi", ".dll", ".scr")) {
        return "Script"
    }

    $signature = Get-AuthenticodeSignature -LiteralPath $File.FullName
    if ($null -eq $signature) {
        return "Unknown"
    }

    return $signature.Status.ToString()
}

Write-TuiHeader -Title "User Executable Review" -Subtitle "Scans Downloads, Temp, and AppData for executable files."

$files = foreach ($root in $roots) {
    if (Test-Path -LiteralPath $root.Path) {
        Get-ChildItem -LiteralPath $root.Path -Recurse -File | Where-Object {
            $extensions -contains $_.Extension.ToLowerInvariant()
        } | ForEach-Object {
            $_ | Add-Member -NotePropertyName RootName -NotePropertyValue $root.Name -PassThru
        }
    }
}

if ($null -eq $files) {
    Write-Host "No executable/script files found in the scanned locations."
    exit 0
}

$files = @($files)

Write-Host "Summary"
$files | Group-Object RootName | Sort-Object Name | ForEach-Object {
    Write-Host ("  {0,-16} {1,4}" -f $_.Name, $_.Count)
}

Write-Host ""
Write-Host "Flagged items"
$flagged = foreach ($file in $files) {
    $trust = Get-TrustStatus -File $file
    if ($trust -ne "Valid") {
        [pscustomobject]@{
            Root = $file.RootName
            Trust = $trust
            Modified = $file.LastWriteTime
            SizeMB = [math]::Round($file.Length / 1MB, 2)
            Path = $file.FullName
        }
    }
}

if ($null -eq $flagged) {
    Write-Host "  None. All signable binaries checked as valid."
}
else {
    $flagged | Sort-Object Modified -Descending | Select-Object -First 30 | Format-Table Root,Trust,Modified,SizeMB,Path -Wrap
}

Write-Host ""
Write-Host "Running user-writable processes"
try {
    $processes = Get-CimInstance Win32_Process | Where-Object {
        $_.ExecutablePath -and (
            $_.ExecutablePath -like "$env:USERPROFILE\*" -or
            $_.ExecutablePath -like "$env:TEMP\*"
        )
    }
}
catch {
    Write-Host "  Could not read process list: $($_.Exception.Message)"
    $processes = $null
}

if ($null -eq $processes) {
    Write-Host "  None found."
}
else {
    $processes | Select-Object ProcessId,Name,ExecutablePath | Format-Table -Wrap
}

Write-Host ""
Write-Host "Startup entries in user-writable locations"
try {
    $startup = Get-CimInstance Win32_StartupCommand | Where-Object {
        $_.Command -match [regex]::Escape($env:USERPROFILE) -or $_.Command -match "AppData|Temp|Downloads"
    }
}
catch {
    Write-Host "  Could not read startup entries: $($_.Exception.Message)"
    $startup = $null
}

if ($null -eq $startup) {
    Write-Host "  None found."
}
else {
    $startup | Select-Object Name,Command,Location | Format-Table -Wrap
}
