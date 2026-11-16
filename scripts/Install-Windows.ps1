[CmdletBinding()]
param(
    [switch]$SkipBuild,
    [switch]$Launch,
    [switch]$LaunchAtLogin = $true,
    [switch]$Uninstall,
    [switch]$RemoveData
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$installRoot = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA "Programs\TopFade"))
$installedExe = Join-Path $installRoot "TopFade.exe"
$receiptPath = Join-Path $installRoot "install-receipt.json"
$shortcutPath = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\TopFade.lnk"
$shortcutDirectory = Split-Path -Parent $shortcutPath
$runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$dataRoot = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA "TopFade"))
$legacyDataRoot = [IO.Path]::GetFullPath((Join-Path $env:APPDATA "TopFade"))

function Assert-ExactManagedPath([string]$Path, [string]$Expected) {
    if (-not [IO.Path]::GetFullPath($Path).Equals(
        [IO.Path]::GetFullPath($Expected),
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Refusing to modify unexpected path: $Path"
    }
}

function Stop-InstalledTopFade {
    $processes = @(Get-Process -Name topfade -ErrorAction SilentlyContinue)
    foreach ($process in $processes) {
        $path = $process.Path
        if ($null -ne $path -and $path.Equals(
            $installedExe,
            [StringComparison]::OrdinalIgnoreCase
        )) {
            Stop-Process -Id $process.Id
            if (-not $process.WaitForExit(5000)) {
                throw "Installed TopFade did not exit within five seconds (PID $($process.Id))."
            }
        }
    }
}

function Get-TopFadeRunValue {
    $properties = Get-ItemProperty -LiteralPath $runKey -Name "TopFade" -ErrorAction SilentlyContinue
    if ($null -eq $properties) {
        return $null
    }
    return $properties.TopFade
}

if ($Uninstall) {
    Assert-ExactManagedPath $installRoot (Join-Path $env:LOCALAPPDATA "Programs\TopFade")
    Stop-InstalledTopFade
    Remove-ItemProperty -LiteralPath $runKey -Name "TopFade" -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $shortcutPath -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $installRoot) {
        Remove-Item -LiteralPath $installRoot -Recurse -Force
    }
    if ($RemoveData) {
        Assert-ExactManagedPath $dataRoot (Join-Path $env:LOCALAPPDATA "TopFade")
        Assert-ExactManagedPath $legacyDataRoot (Join-Path $env:APPDATA "TopFade")
        if (Test-Path -LiteralPath $dataRoot) {
            Remove-Item -LiteralPath $dataRoot -Recurse -Force
        }
        if (Test-Path -LiteralPath $legacyDataRoot) {
            Remove-Item -LiteralPath $legacyDataRoot -Recurse -Force
        }
    }
    [pscustomobject]@{
        action = "uninstall"
        application_removed = -not (Test-Path -LiteralPath $installRoot)
        data_preserved = -not $RemoveData
        windowtop_untouched = $true
    } | ConvertTo-Json
    return
}

if (-not $SkipBuild) {
    Push-Location $projectRoot
    try {
        cargo build --release --locked
        if ($LASTEXITCODE -ne 0) {
            throw "cargo build --release failed with exit code $LASTEXITCODE"
        }
    } finally {
        Pop-Location
    }
}

$sourceExe = Join-Path $projectRoot "target\release\topfade.exe"
if (-not (Test-Path -LiteralPath $sourceExe -PathType Leaf)) {
    throw "Release executable not found: $sourceExe"
}

Stop-InstalledTopFade
$hadInstallRoot = Test-Path -LiteralPath $installRoot
New-Item -ItemType Directory -Force -Path $installRoot | Out-Null
$stagedExe = Join-Path $installRoot "TopFade.new.exe"
$previousExe = Join-Path $installRoot "TopFade.previous.exe"
$shortcutBackup = Join-Path $installRoot "TopFade.previous.lnk"
$receiptStage = Join-Path $installRoot "install-receipt.new.json"
$receiptBackup = Join-Path $installRoot "install-receipt.rollback.json"
$hadInstalledExe = Test-Path -LiteralPath $installedExe
$hadShortcut = Test-Path -LiteralPath $shortcutPath
$hadReceipt = Test-Path -LiteralPath $receiptPath
$previousRunValue = Get-TopFadeRunValue
$sourceHash = (Get-FileHash -LiteralPath $sourceExe -Algorithm SHA256).Hash
$promoted = $false
try {
    Remove-Item `
        -LiteralPath $stagedExe, $shortcutBackup, $receiptStage, $receiptBackup `
        -Force `
        -ErrorAction SilentlyContinue
    Copy-Item -LiteralPath $sourceExe -Destination $stagedExe -Force
    if ((Get-Item -LiteralPath $stagedExe).Length -lt 1MB) {
        throw "Staged executable is unexpectedly small; refusing installation."
    }
    $stagedHash = (Get-FileHash -LiteralPath $stagedExe -Algorithm SHA256).Hash
    if ($stagedHash -ne $sourceHash) {
        throw "Staged executable hash does not match the release source."
    }
    if ($hadInstalledExe) {
        Copy-Item -LiteralPath $installedExe -Destination $previousExe -Force
    } else {
        Remove-Item -LiteralPath $previousExe -Force -ErrorAction SilentlyContinue
    }
    if ($hadShortcut) {
        Copy-Item -LiteralPath $shortcutPath -Destination $shortcutBackup -Force
    }
    if ($hadReceipt) {
        Copy-Item -LiteralPath $receiptPath -Destination $receiptBackup -Force
    }

    Move-Item -LiteralPath $stagedExe -Destination $installedExe -Force
    $promoted = $true
    $installedHash = (Get-FileHash -LiteralPath $installedExe -Algorithm SHA256).Hash
    if ($installedHash -ne $sourceHash) {
        throw "Installed executable hash does not match the verified staged release."
    }

    New-Item -ItemType Directory -Force -Path $shortcutDirectory | Out-Null
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $installedExe
    $shortcut.WorkingDirectory = $installRoot
    $shortcut.Description = "Pin and fade windows with TopFade"
    $shortcut.IconLocation = "$installedExe,0"
    $shortcut.Save()

    if ($LaunchAtLogin) {
        New-Item -Path $runKey -Force | Out-Null
        Set-ItemProperty -LiteralPath $runKey -Name "TopFade" -Value "`"$installedExe`""
    } else {
        Remove-ItemProperty -LiteralPath $runKey -Name "TopFade" -ErrorAction SilentlyContinue
    }

    $activeRunValue = Get-TopFadeRunValue
    $expectedRunValue = "`"$installedExe`""
    if ($LaunchAtLogin -and $activeRunValue -ne $expectedRunValue) {
        throw "Launch-at-login registration did not match the installed executable."
    }
    if (-not $LaunchAtLogin -and $null -ne $activeRunValue) {
        throw "A stale TopFade launch-at-login value remained after installation."
    }

    $receipt = [ordered]@{
        action = "install"
        installed_utc = [DateTime]::UtcNow.ToString("o")
        source = $sourceExe
        destination = $installedExe
        bytes = (Get-Item -LiteralPath $installedExe).Length
        sha256 = $installedHash
        shortcut = $shortcutPath
        launch_at_login = $activeRunValue -eq $expectedRunValue
        previous_binary_preserved = Test-Path -LiteralPath $previousExe
        data_directory = $dataRoot
        data_preserved = $true
        windowtop_untouched = $true
    }
    $receipt | ConvertTo-Json | Set-Content -LiteralPath $receiptStage -Encoding UTF8
    Move-Item -LiteralPath $receiptStage -Destination $receiptPath -Force
} catch {
    Remove-Item -LiteralPath $stagedExe -Force -ErrorAction SilentlyContinue
    if ($promoted) {
        if ($hadInstalledExe -and (Test-Path -LiteralPath $previousExe)) {
            Copy-Item -LiteralPath $previousExe -Destination $installedExe -Force
        } else {
            Remove-Item -LiteralPath $installedExe -Force -ErrorAction SilentlyContinue
        }
    }
    if ($null -ne $previousRunValue) {
        New-Item -Path $runKey -Force | Out-Null
        Set-ItemProperty -LiteralPath $runKey -Name "TopFade" -Value $previousRunValue
    } else {
        Remove-ItemProperty -LiteralPath $runKey -Name "TopFade" -ErrorAction SilentlyContinue
    }
    if ($hadShortcut) {
        if (Test-Path -LiteralPath $shortcutBackup) {
            Copy-Item -LiteralPath $shortcutBackup -Destination $shortcutPath -Force
        }
    } else {
        Remove-Item -LiteralPath $shortcutPath -Force -ErrorAction SilentlyContinue
    }
    if ($hadReceipt -and (Test-Path -LiteralPath $receiptBackup)) {
        Copy-Item -LiteralPath $receiptBackup -Destination $receiptPath -Force
    } elseif (-not $hadReceipt) {
        Remove-Item -LiteralPath $receiptPath -Force -ErrorAction SilentlyContinue
    }
    if (-not $hadInstallRoot -and (Test-Path -LiteralPath $installRoot)) {
        $remaining = @(Get-ChildItem -LiteralPath $installRoot -Force)
        if ($remaining.Count -eq 0) {
            Remove-Item -LiteralPath $installRoot -Force
        }
    }
    throw "TopFade installation failed and the previous installation state was restored: $($_.Exception.Message)"
} finally {
    Remove-Item `
        -LiteralPath $stagedExe, $shortcutBackup, $receiptStage, $receiptBackup `
        -Force `
        -ErrorAction SilentlyContinue
}

if ($Launch) {
    Start-Process -FilePath $installedExe | Out-Null
}

Get-Content -LiteralPath $receiptPath
