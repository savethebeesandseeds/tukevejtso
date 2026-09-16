# Convert the already sorted scan results into display rows. FileIndex always
# refers to the original input so folder headings never become selectable PDFs.
function Get-PdfTreeRows {
    param([AllowEmptyCollection()][object[]] $Files = @())

    $nodes = New-Object 'System.Collections.Generic.List[object]'
    $folders = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    $lastChild = New-Object 'System.Collections.Generic.Dictionary[string,int]' ([StringComparer]::OrdinalIgnoreCase)

    for ($fileIndex = 0; $fileIndex -lt $Files.Count; $fileIndex++) {
        $parts = @(([string]$Files[$fileIndex].relative) -split '[\\/]' | Where-Object { $_.Length -gt 0 })
        if (-not $parts.Count) { continue }
        $parentKey = ''
        $parent = $null
        for ($depth = 0; $depth -lt $parts.Count - 1; $depth++) {
            $key = $parentKey + $parts[$depth] + '/'
            if (-not $folders.ContainsKey($key)) {
                $folder = [pscustomobject]@{
                    Id = $nodes.Count
                    Parent = $parent
                    ParentKey = $parentKey
                    FileIndex = -1
                    IsFolder = $true
                    Depth = $depth
                    Label = $parts[$depth] + '/'
                }
                $nodes.Add($folder)
                $folders.Add($key, $folder)
                $lastChild[$parentKey] = $folder.Id
            }
            $parent = $folders[$key]
            $parentKey = $key
        }
        $file = [pscustomobject]@{
            Id = $nodes.Count
            Parent = $parent
            ParentKey = $parentKey
            FileIndex = $fileIndex
            IsFolder = $false
            Depth = $parts.Count - 1
            Label = $parts[$parts.Count - 1]
        }
        $nodes.Add($file)
        $lastChild[$parentKey] = $file.Id
    }

    # Keep this source ASCII so Windows PowerShell 5.1 does not require a BOM.
    $branch = [string][char]0x251c + [char]0x2500 + [char]0x2500 + ' '
    $endBranch = [string][char]0x2514 + [char]0x2500 + [char]0x2500 + ' '
    $continuation = [string][char]0x2502 + '   '
    foreach ($node in $nodes) {
        $prefix = if ($lastChild[$node.ParentKey] -eq $node.Id) { $endBranch } else { $branch }
        $ancestor = $node.Parent
        while ($null -ne $ancestor) {
            $column = if ($lastChild[$ancestor.ParentKey] -eq $ancestor.Id) { '    ' } else { $continuation }
            $prefix = $column + $prefix
            $ancestor = $ancestor.Parent
        }
        [pscustomobject]@{
            FileIndex = [int]$node.FileIndex
            IsFolder = [bool]$node.IsFolder
            Depth = [int]$node.Depth
            Prefix = $prefix
            Label = $node.Label
        }
    }
}
