param([string] $OutputPath = (Join-Path $env:TEMP 'tukevejtso-audio-checks.html'))
$ErrorActionPreference = 'Stop'
# File preparation only. All actual JavaScript checks run in the user's browser.
$html = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\audio-test.html'))
$dsp = [regex]::Match($html, '(?s)<script id="dsp">(.*?)</script>').Groups[1].Value
if (-not $dsp) { throw 'Production DSP script was not found.' }
$capture = [regex]::Match($html, '(?s)<script id="capture">(.*?)</script>').Groups[1].Value
if (-not $capture) { throw 'Production capture script was not found.' }
$checks = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'audio-test-checks.js'))
$page = @"
<!doctype html><html lang="en"><meta charset="utf-8"><title>Audio lab engine checks</title>
<body style="background:#10151b;color:#e9eff5;font:16px/1.8 system-ui;padding:36px">
<h1>Audio lab engine checks</h1><p id="result">Running…</p><ol id="checks"></ol>
<p>Checks use the exact DSP and capture code from the installed HTML. Capture lifecycle tests use simulated browser buffers. No audio devices or network access are used.</p>
<script>$dsp</script><script>$capture</script><script>$checks</script></body></html>
"@
[IO.File]::WriteAllText($OutputPath, $page, [Text.UTF8Encoding]::new($false))
Write-Output $OutputPath
