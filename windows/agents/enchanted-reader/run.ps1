param()

$ErrorActionPreference = "Stop"

$AgentRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$OpenAiKeyPath = Join-Path $env:APPDATA "tukevejtso\secrets\openai-api-key.dpapi"

function ConvertFrom-SecureStringToPlainText {
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

function Get-StoredOpenAiApiKey {
    try {
        if (-not (Test-Path -LiteralPath $OpenAiKeyPath -PathType Leaf)) {
            return $null
        }
        $encrypted = (Get-Content -LiteralPath $OpenAiKeyPath -Raw).Trim()
        if ([string]::IsNullOrWhiteSpace($encrypted)) {
            return $null
        }
        $secureKey = ConvertTo-SecureString -String $encrypted
        $plainKey = ConvertFrom-SecureStringToPlainText -SecureValue $secureKey
        if (-not [string]::IsNullOrWhiteSpace($plainKey)) {
            return $plainKey.Trim()
        }
    }
    catch {
        return $null
    }
    finally {
        $plainKey = $null
    }
    return $null
}

$readerExe = Join-Path $AgentRoot "target\release\enchanted-reader.exe"
if (-not (Test-Path -LiteralPath $readerExe -PathType Leaf)) {
    throw "Enchanted Reader's Windows executable is missing: $readerExe"
}
$openAiApiKeyEnvironmentExisted = Test-Path Env:OPENAI_API_KEY
$previousOpenAiApiKeyEnvironment = $env:OPENAI_API_KEY
$agentExitCode = 0

try {
    $plainKey = Get-StoredOpenAiApiKey
    if (-not [string]::IsNullOrWhiteSpace($plainKey)) {
        $env:OPENAI_API_KEY = $plainKey.Trim()
    }
    $plainKey = $null

    & $readerExe --agent-root $AgentRoot
    if ($null -ne $LASTEXITCODE) {
        $agentExitCode = $LASTEXITCODE
    }
}
finally {
    if ($openAiApiKeyEnvironmentExisted) {
        $env:OPENAI_API_KEY = $previousOpenAiApiKeyEnvironment
    }
    else {
        Remove-Item Env:OPENAI_API_KEY -ErrorAction SilentlyContinue
    }
}

if ($agentExitCode -ne 0) {
    exit $agentExitCode
}
