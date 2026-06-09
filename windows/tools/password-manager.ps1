param(
    [ValidateRange(8, 128)]
    [int] $Length = 32,

    [ValidateSet("Simple", "Balanced", "Strong")]
    [string] $Complexity = "Strong",

    [switch] $NoMenu
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "ui.ps1")

$script:PasswordRng = [System.Security.Cryptography.RandomNumberGenerator]::Create()

function Get-SecureRandomInt {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(1, [int]::MaxValue)]
        [int] $ExclusiveMax
    )

    $bytes = New-Object byte[] 4
    $rangeSize = ([uint64] [uint32]::MaxValue) + 1
    $limit = $rangeSize - ($rangeSize % [uint64] $ExclusiveMax)

    do {
        $script:PasswordRng.GetBytes($bytes)
        $value = [uint64] [BitConverter]::ToUInt32($bytes, 0)
    } while ($value -ge $limit)

    return [int] ($value % [uint64] $ExclusiveMax)
}

function Get-RandomPasswordChar {
    param(
        [Parameter(Mandatory = $true)]
        [char[]] $Characters
    )

    return $Characters[(Get-SecureRandomInt -ExclusiveMax $Characters.Count)]
}

function New-StrongPassword {
    param(
        [ValidateRange(8, 128)]
        [int] $PasswordLength = 32,

        [ValidateSet("Simple", "Balanced", "Strong")]
        [string] $PasswordComplexity = "Strong"
    )

    $profile = Get-PasswordComplexityProfile -Name $PasswordComplexity
    $sets = $profile.CharacterSets

    if ($PasswordLength -lt $sets.Count) {
        throw "Password length must be at least $($sets.Count)."
    }

    $pool = New-Object "System.Collections.Generic.List[char]"
    foreach ($set in $sets) {
        foreach ($character in $set) {
            $pool.Add($character)
        }
    }

    $password = New-Object "System.Collections.Generic.List[char]"
    foreach ($set in $sets) {
        $password.Add((Get-RandomPasswordChar -Characters $set))
    }

    while ($password.Count -lt $PasswordLength) {
        $password.Add((Get-RandomPasswordChar -Characters $pool.ToArray()))
    }

    $shuffled = $password.ToArray()
    for ($index = $shuffled.Count - 1; $index -gt 0; $index--) {
        $swapIndex = Get-SecureRandomInt -ExclusiveMax ($index + 1)
        $temporary = $shuffled[$index]
        $shuffled[$index] = $shuffled[$swapIndex]
        $shuffled[$swapIndex] = $temporary
    }

    return -join $shuffled
}

function Get-PasswordComplexityProfile {
    param(
        [ValidateSet("Simple", "Balanced", "Strong")]
        [string] $Name
    )

    $lowercase = [char[]] "abcdefghijklmnopqrstuvwxyz"
    $uppercase = [char[]] "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    $digits = [char[]] "0123456789"
    $safeSymbols = [char[]] '!@#$%*-_=+?'
    $fullSymbols = [char[]] '!@#$%^&*()-_=+[]{};:,.?/'

    switch ($Name) {
        "Simple" {
            return [pscustomobject]@{
                Name = "Simple"
                Label = "Simple"
                Detail = "letters and digits"
                CharacterSets = @($lowercase, $uppercase, $digits)
            }
        }
        "Balanced" {
            return [pscustomobject]@{
                Name = "Balanced"
                Label = "Balanced"
                Detail = "letters, digits, safe symbols"
                CharacterSets = @($lowercase, $uppercase, $digits, $safeSymbols)
            }
        }
        default {
            return [pscustomobject]@{
                Name = "Strong"
                Label = "Strong"
                Detail = "letters, digits, wider symbols"
                CharacterSets = @($lowercase, $uppercase, $digits, $fullSymbols)
            }
        }
    }
}

function Render-PasswordMainMenuItem {
    param(
        [hashtable] $Item,
        [int] $Index,
        [bool] $Selected,
        [string] $Number
    )

    if ($Selected) {
        Write-Host ("> " + $Item.Label) -ForegroundColor Cyan
        return
    }

    Write-Host ("  " + $Item.Label) -ForegroundColor Gray
}

function Read-PasswordLength {
    param([int] $CurrentLength)

    while ($true) {
        Write-TuiHeader -Title "Password Manager" -Subtitle "Length"
        Write-Host "Enter the password length from 8 to 128." -ForegroundColor Gray
        Write-Host ("Press Enter to keep [{0}]." -f $CurrentLength) -ForegroundColor DarkGray
        Write-Host ""

        $rawValue = Read-Host ("Length [{0}]" -f $CurrentLength)
        if ([string]::IsNullOrWhiteSpace($rawValue)) {
            return $CurrentLength
        }

        $parsed = 0
        if ([int]::TryParse($rawValue, [ref] $parsed) -and $parsed -ge 8 -and $parsed -le 128) {
            return $parsed
        }

        Write-Host ""
        Write-Host "Use a whole number from 8 to 128." -ForegroundColor Yellow
        Write-Host "Press any key to try again..." -ForegroundColor DarkGray
        [void][Console]::ReadKey($true)
    }
}

function Format-PasswordComplexityOption {
    param(
        [hashtable] $Option,
        [bool] $Selected,
        [bool] $Current
    )

    $marker = if ($Selected) { "> " } else { "  " }
    $currentText = if ($Current) { " [current]" } else { "" }
    $text = "{0}{1,-8} {2}{3}" -f $marker, $Option.Name, $Option.Detail, $currentText

    if ($Selected) {
        return (Format-TuiAnsiText -Text $text -Foreground "#000000" -Background "#5dd9e8")
    }

    return (Format-TuiAnsiText -Text $text -Foreground "#d7d7d7")
}

function Read-PasswordComplexity {
    param(
        [ValidateSet("Simple", "Balanced", "Strong")]
        [string] $CurrentComplexity
    )

    $options = @(
        @{ Key = "1"; Name = "Simple"; Detail = "letters and digits" },
        @{ Key = "2"; Name = "Balanced"; Detail = "letters, digits, safe symbols" },
        @{ Key = "3"; Name = "Strong"; Detail = "letters, digits, wider symbols" }
    )

    $selected = 0
    for ($index = 0; $index -lt $options.Count; $index++) {
        if ($options[$index].Name -eq $CurrentComplexity) {
            $selected = $index
            break
        }
    }

    $renderedOnce = $false
    try {
        while ($true) {
            $frameLines = New-Object System.Collections.Generic.List[string]
            foreach ($line in (Get-TuiHeaderLines -Title "Password Manager" -Subtitle "Complexity")) {
                $frameLines.Add($line)
            }

            $frameLines.Add((Format-TuiAnsiText -Text ("Current [{0}]" -f $CurrentComplexity) -Foreground "#777777"))
            $frameLines.Add("")

            for ($index = 0; $index -lt $options.Count; $index++) {
                $frameLines.Add((Format-PasswordComplexityOption `
                    -Option $options[$index] `
                    -Selected:($index -eq $selected) `
                    -Current:($options[$index].Name -eq $CurrentComplexity)))
            }

            $frameLines.Add("")
            $frameLines.Add((Get-TuiHelpLine))
            Write-TuiFrame -Lines ([string[]]$frameLines) -Initial:(-not $renderedOnce)
            $renderedOnce = $true

            if ([Console]::IsInputRedirected) {
                return $CurrentComplexity
            }

            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                "UpArrow" {
                    $selected--
                    if ($selected -lt 0) { $selected = $options.Count - 1 }
                }
                "DownArrow" {
                    $selected++
                    if ($selected -ge $options.Count) { $selected = 0 }
                }
                "Home" {
                    $selected = 0
                }
                "End" {
                    $selected = $options.Count - 1
                }
                "Enter" {
                    return $options[$selected].Name
                }
                "Escape" {
                    return $CurrentComplexity
                }
                "Q" {
                    return $CurrentComplexity
                }
                default {
                    if ($key.KeyChar -match "^[1-3]$") {
                        return $options[[int]::Parse($key.KeyChar.ToString()) - 1].Name
                    }
                }
            }
        }
    }
    finally {
        Show-TuiCursor
    }
}

function Invoke-PasswordGeneration {
    param(
        [ValidateRange(8, 128)]
        [int] $CurrentLength,

        [ValidateSet("Simple", "Balanced", "Strong")]
        [string] $CurrentComplexity
    )

    $selectedLength = Read-PasswordLength -CurrentLength $CurrentLength
    $selectedComplexity = Read-PasswordComplexity -CurrentComplexity $CurrentComplexity
    $password = New-StrongPassword -PasswordLength $selectedLength -PasswordComplexity $selectedComplexity

    Clear-Host
    Write-Host $password
    Write-Host ""
    Write-Host "Press any key to return..." -ForegroundColor DarkGray
    [void][Console]::ReadKey($true)

    return [pscustomobject]@{
        Length = $selectedLength
        Complexity = $selectedComplexity
    }
}

function Invoke-PasswordManagerMenu {
    param(
        [ValidateRange(8, 128)]
        [int] $InitialLength,

        [ValidateSet("Simple", "Balanced", "Strong")]
        [string] $InitialComplexity
    )

    $selectedLength = $InitialLength
    $selectedComplexity = $InitialComplexity

    while ($true) {
        $items = @(
            @{
                Label = "Generate password"
                Action = "generate"
            },
            @{
                Label = "Cancel"
                Action = "cancel"
            }
        )

        $choice = Select-TuiItem `
            -Title "Password Manager" `
            -Subtitle "Use Up/Down and Enter." `
            -Items $items `
            -RenderItem ${function:Render-PasswordMainMenuItem}

        if ($null -eq $choice -or $choice.Action -eq "cancel") {
            return
        }

        $result = Invoke-PasswordGeneration -CurrentLength $selectedLength -CurrentComplexity $selectedComplexity
        $selectedLength = $result.Length
        $selectedComplexity = $result.Complexity
    }
}

try {
    if ([Console]::IsInputRedirected -or $NoMenu) {
        Write-Output (New-StrongPassword -PasswordLength $Length -PasswordComplexity $Complexity)
        return
    }

    Invoke-PasswordManagerMenu -InitialLength $Length -InitialComplexity $Complexity
}
finally {
    if ($null -ne $script:PasswordRng) {
        $script:PasswordRng.Dispose()
    }
}
