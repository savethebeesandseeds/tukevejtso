# Run with Windows PowerShell 5.1; no Pester dependency is required.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\pdf-tree.ps1')
$script:Passed = 0
$script:Failures = New-Object 'System.Collections.Generic.List[string]'

function Assert-True([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}
function Assert-Sequence($Actual, $Expected, [string] $Message) {
    $a = @($Actual) -join "`n"
    $e = @($Expected) -join "`n"
    if ($a -cne $e) { throw "$Message -- expected [$e], received [$a]" }
}
function Test-Case([string] $Name, [scriptblock] $Body) {
    try { & $Body; $script:Passed++; Write-Host "PASS $Name" }
    catch { $script:Failures.Add("$Name : $($_.Exception.Message)"); Write-Host "FAIL $Name : $($_.Exception.Message)" }
}
function New-Files([string[]] $Names) {
    foreach ($name in $Names) { [pscustomobject]@{ relative = $name; path = 'C:\fixtures\' + $name; size = 123 } }
}
function Get-Lines($Rows) {
    foreach ($row in $Rows) { $row.Prefix + $row.Label }
}

$branch = [string][char]0x251c + [char]0x2500 + [char]0x2500 + ' '
$endBranch = [string][char]0x2514 + [char]0x2500 + [char]0x2500 + ' '
$vertical = [string][char]0x2502 + '   '

Test-Case 'PowerShell 5.1 runtime' {
    Assert-True ($PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -eq 1) 'Run this test with powershell.exe, not pwsh.'
}
Test-Case 'Root files, nested folders and sibling continuations have exact tree lines' {
    $files = @(New-Files @('1-root.pdf', '2-group\1-first.pdf', '2-group\2-sub\1-deep.pdf', '2-group\2-sub\2-deep.pdf', '2-group\3-last.pdf', '3-sibling/only.pdf', '4-final.pdf'))
    $rows = @(Get-PdfTreeRows -Files $files)
    Assert-Sequence (Get-Lines $rows) @(
        ($branch + '1-root.pdf'),
        ($branch + '2-group/'),
        ($vertical + $branch + '1-first.pdf'),
        ($vertical + $branch + '2-sub/'),
        ($vertical + $vertical + $branch + '1-deep.pdf'),
        ($vertical + $vertical + $endBranch + '2-deep.pdf'),
        ($vertical + $endBranch + '3-last.pdf'),
        ($branch + '3-sibling/'),
        ($vertical + $endBranch + 'only.pdf'),
        ($endBranch + '4-final.pdf')
    ) 'Tree must retain every continuing ancestor branch'
    Assert-Sequence ($rows | ForEach-Object Depth) @(0, 0, 1, 1, 2, 2, 1, 0, 1, 0) 'Depth must describe indentation below the separately rendered search root'
    Assert-Sequence ($rows | Where-Object { -not $_.IsFolder } | ForEach-Object FileIndex) @(0, 1, 2, 3, 4, 5, 6) 'File indices must retain original scan order'
    Assert-True (@($rows | Where-Object { $_.IsFolder -and $_.FileIndex -ne -1 }).Count -eq 0) 'Folder headings must never identify a selectable PDF'
}
Test-Case 'Last-folder descendants do not draw a spurious continuation' {
    $rows = @(Get-PdfTreeRows -Files @(New-Files @('a/one.pdf', 'b/sub/one.pdf', 'b/sub/two.pdf')))
    Assert-Sequence (Get-Lines $rows) @(
        ($branch + 'a/'),
        ($vertical + $endBranch + 'one.pdf'),
        ($endBranch + 'b/'),
        ('    ' + $endBranch + 'sub/'),
        ('        ' + $branch + 'one.pdf'),
        ('        ' + $endBranch + 'two.pdf')
    ) 'Last branches must leave empty ancestor columns'
}
Test-Case 'Windows folder identity is case insensitive and preserves Unicode labels' {
    $folder = 'M' + [char]0x171 + 'hely'
    $name = [string][char]0x6771 + [char]0x4eac + '.PDF'
    $files = @(New-Files @(($folder + '\1-first.pdf'), ($folder.ToUpperInvariant() + '/' + $name)))
    $before = $files | ConvertTo-Json -Compress
    $rows = @(Get-PdfTreeRows -Files $files)
    Assert-Sequence (Get-Lines $rows) @(
        ($endBranch + $folder + '/'),
        ('    ' + $branch + '1-first.pdf'),
        ('    ' + $endBranch + $name)
    ) 'Equivalent Windows folders must share one heading and retain original names'
    Assert-True (($files | ConvertTo-Json -Compress) -ceq $before) 'Rendering must not mutate scan results'
}
Test-Case 'Filtered files produce only matching ancestors and keep result indices' {
    $rows = @(Get-PdfTreeRows -Files @(New-Files @('documents/contracts/signed.pdf', 'receipts/paid.pdf')))
    Assert-Sequence (Get-Lines $rows) @(
        ($branch + 'documents/'),
        ($vertical + $endBranch + 'contracts/'),
        ($vertical + '    ' + $endBranch + 'signed.pdf'),
        ($endBranch + 'receipts/'),
        ('    ' + $endBranch + 'paid.pdf')
    ) 'Filtered results should have complete ancestor context and no empty folders'
    Assert-Sequence ($rows | Where-Object { -not $_.IsFolder } | ForEach-Object FileIndex) @(0, 1) 'Filtered file indices must address the supplied result list'
}
Test-Case 'Natural scan order is preserved for numbered files and folders' {
    $rows = @(Get-PdfTreeRows -Files @(New-Files @('2-folder/2.pdf', '2-folder/10.pdf', '10-folder/2.pdf', '10-folder/10.pdf')))
    Assert-Sequence ($rows | ForEach-Object Label) @('2-folder/', '2.pdf', '10.pdf', '10-folder/', '2.pdf', '10.pdf') 'Renderer must not replace natural ordering with lexicographic sorting'
}
Test-Case 'Empty and singleton scans are valid trees' {
    Assert-True (@(Get-PdfTreeRows -Files @()).Count -eq 0) 'Empty scans should produce no tree rows'
    Assert-True (@(Get-PdfTreeRows -Files $null).Count -eq 0) 'Null scans should produce no tree rows'
    $rows = @(Get-PdfTreeRows -Files @(New-Files @('only.pdf')))
    Assert-Sequence (Get-Lines $rows) @(($endBranch + 'only.pdf')) 'A singleton root PDF is the final branch'
    Assert-True ($rows[0].FileIndex -eq 0 -and -not $rows[0].IsFolder -and $rows[0].Depth -eq 0) 'Singleton row metadata is incorrect'
}

Write-Host ("{0} passed; {1} failed." -f $script:Passed, $script:Failures.Count)
if ($script:Failures.Count) { throw ($script:Failures -join "`n") }
