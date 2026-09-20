# Shared local Python discovery and UTF-8 JSON transport for PDF tools.
function Invoke-PdfBackend {
    param([hashtable] $Request, [string] $Python = $script:PdfPython)
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $Python
    $info.Arguments = '-X utf8 "' + $script:PdfBackend + '"'
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $info.StandardOutputEncoding = $utf8
    $info.StandardErrorEncoding = $utf8
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info
    try {
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $payload = $utf8.GetBytes(($Request | ConvertTo-Json -Depth 8 -Compress))
        $process.StandardInput.BaseStream.Write($payload, 0, $payload.Length)
        $process.StandardInput.Close()
        $process.WaitForExit()
        $text = $stdout.GetAwaiter().GetResult()
        $errors = $stderr.GetAwaiter().GetResult()
        try { $result = $text | ConvertFrom-Json } catch { throw "PDF engine failed: $errors $text" }
        if ($null -eq $result -or -not $result.ok) { throw "PDF engine: $($result.error)" }
        if ($process.ExitCode -ne 0) { throw "PDF engine failed: $errors" }
        return $result
    }
    finally { $process.Dispose() }
}

function Find-PdfPython {
    param([string] $DependencyHint = 'Python 3.10+ with pypdf 6 is required. Install Python, then run: py -m pip install "pypdf>=6,<7". Or set TUKEVEJTSO_PDF_PYTHON to a Python executable with pypdf installed.')
    $candidates = New-Object 'System.Collections.Generic.List[string]'
    if ($env:TUKEVEJTSO_PDF_PYTHON) { $candidates.Add($env:TUKEVEJTSO_PDF_PYTHON) }
    else {
        foreach ($name in @('python.exe', 'python3.exe')) {
            $cmd = Get-Command $name -ErrorAction SilentlyContinue
            if ($cmd -and $cmd.Source -notlike '*\WindowsApps\*') { $candidates.Add($cmd.Source) }
        }
        $py = Get-Command py.exe -ErrorAction SilentlyContinue
        if ($py) {
            $resolved = & $py.Source -3 -c 'import sys; print(sys.executable)' 2>$null
            if ($LASTEXITCODE -eq 0 -and $resolved) { $candidates.Add([string]$resolved) }
        }
        $candidates.Add((Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'))
    }
    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        try {
            [void](Invoke-PdfBackend -Request @{ action = 'probe' } -Python $candidate)
            return $candidate
        } catch { $script:PdfNotice = $_.Exception.Message }
    }
    throw $DependencyHint
}

