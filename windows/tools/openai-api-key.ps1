param(
    [switch]$Set,
    [switch]$Status,
    [switch]$Clear
)

$ErrorActionPreference = "Stop"

$StoreDir = Join-Path $env:APPDATA "tukevejtso\secrets"
$KeyPath = Join-Path $StoreDir "openai-api-key.dpapi"

function ConvertTo-PlainText {
    param([securestring]$SecureValue)

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}

function Test-KeyFile {
    return (Test-Path -LiteralPath $KeyPath -PathType Leaf)
}

$actionCount = @(@($Set, $Status, $Clear) | Where-Object { $_ }).Count
if ($actionCount -gt 1) {
    throw "Use only one action: -Set, -Status, or -Clear."
}

if ($actionCount -eq 0) {
    $Set = $true
}

if ($Set) {
    New-Item -ItemType Directory -Force -Path $StoreDir | Out-Null
    $secureKey = Read-Host "OpenAI API key" -AsSecureString
    $plain = ConvertTo-PlainText -SecureValue $secureKey
    try {
        if ([string]::IsNullOrWhiteSpace($plain)) {
            throw "The API key was empty."
        }
        if ($plain.Trim() -ne $plain) {
            $secureKey = ConvertTo-SecureString -String $plain.Trim() -AsPlainText -Force
        }
    }
    finally {
        $plain = $null
    }

    $secureKey | ConvertFrom-SecureString | Set-Content -LiteralPath $KeyPath -Encoding ASCII -NoNewline
    Write-Host "OpenAI API key stored for this Windows user." -ForegroundColor Green
    Write-Host $KeyPath -ForegroundColor DarkGray
    return
}

if ($Clear) {
    if (Test-KeyFile) {
        Remove-Item -LiteralPath $KeyPath -Force
        Write-Host "OpenAI API key removed." -ForegroundColor Green
    }
    else {
        Write-Host "No OpenAI API key is stored." -ForegroundColor Yellow
    }
    return
}

if ($Status -or -not ($Set -or $Clear)) {
    if (Test-KeyFile) {
        Write-Host "OpenAI API key is stored for this Windows user." -ForegroundColor Green
        Write-Host $KeyPath -ForegroundColor DarkGray
    }
    else {
        Write-Host "No OpenAI API key is stored." -ForegroundColor Yellow
        Write-Host "Run: tk openai-key" -ForegroundColor DarkGray
    }
}
