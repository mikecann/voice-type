# Test registration safely with a fake WScript.Shell and login registry.
# This runs on pwsh/macOS too; real Windows launch behaviour needs a smoke test.
$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('voice-type-install-' + [guid]::NewGuid())
$oldOS = $env:OS
$oldAppData = $env:APPDATA
$oldSystemRoot = $env:SystemRoot

function Assert-True($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function New-Object {
    param([string]$ComObject)
    if ($ComObject -ne 'WScript.Shell') { throw "Unexpected COM object: $ComObject" }
    $shell = [pscustomobject]@{}
    $shell | Add-Member -MemberType ScriptMethod -Name CreateShortcut -Value {
        param($Path)
        $shortcut = [pscustomobject]@{
            Path = $Path
            TargetPath = ''
            Arguments = ''
            WorkingDirectory = ''
            Description = ''
            IconLocation = ''
        }
        if (Test-Path -LiteralPath $Path) {
            $saved = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
            $shortcut.Arguments = $saved.Arguments
        }
        $shortcut | Add-Member -MemberType ScriptMethod -Name Save -Value {
            $this | ConvertTo-Json | Set-Content -LiteralPath $this.Path
        }
        return $shortcut
    }
    return $shell
}

function Get-ItemProperty {
    [CmdletBinding()]
    param([string]$LiteralPath, [string]$Name)
    Assert-True ($Name -eq 'VoiceType') 'Uninstall queried another tool login entry.'
    return [pscustomobject]@{ VoiceType = $global:VoiceTypeTestStartupCommand }
}

function Remove-ItemProperty {
    [CmdletBinding()]
    param([string]$LiteralPath, [string]$Name)
    Assert-True ($Name -eq 'VoiceType') 'Uninstall removed another tool login entry.'
    $global:VoiceTypeTestStartupCommand = $null
}

try {
    $clone = Join-Path $TestRoot 'clone with spaces'
    $tools = Join-Path $TestRoot 'tools'
    New-Item -ItemType Directory -Path $clone -Force | Out-Null
    foreach ($name in @('install.ps1', 'uninstall.ps1', 'settings.example.json')) {
        Copy-Item -LiteralPath (Join-Path $RepoRoot $name) -Destination $clone
    }
    Set-Content -LiteralPath (Join-Path $clone 'deps.ps1') -Value 'Set-Content -LiteralPath (Join-Path $PSScriptRoot "deps-ran") -Value "yes"'
    $env:OS = 'Windows_NT'
    $env:APPDATA = Join-Path $TestRoot 'appdata'
    $env:SystemRoot = Join-Path $TestRoot 'windows'
    & (Join-Path $clone 'install.ps1') -ToolsDir $tools
    Assert-True (Test-Path -LiteralPath (Join-Path $clone 'deps-ran')) 'Installer did not run deps.ps1.'
    $settings = Join-Path $clone 'settings.json'
    Assert-True (Test-Path -LiteralPath $settings) 'Installer did not seed settings.'
    Set-Content -LiteralPath $settings -Value '{"microphone_name":"My mic"}'
    Remove-Item -LiteralPath (Join-Path $clone 'deps-ran')
    & (Join-Path $clone 'install.ps1') -ToolsDir $tools -SkipDeps
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $clone 'deps-ran'))) '-SkipDeps ran dependencies.'
    Assert-True ((Get-Content -LiteralPath $settings -Raw) -match 'My mic') 'Reinstall overwrote user settings.'

    $vbs = Join-Path $clone 'voice-type.vbs'
    $shortcut = Get-Content -LiteralPath (Join-Path $tools 'Voice Type.lnk') -Raw | ConvertFrom-Json
    Assert-True ($shortcut.Arguments -eq "`"$vbs`"") 'Shortcut does not point to this clone VBS.'
    Assert-True ($shortcut.TargetPath -like '*wscript.exe') 'Shortcut bypasses the silent VBS launcher.'
    Assert-True ($shortcut.WorkingDirectory -eq $clone) 'Shortcut uses the wrong working directory.'
    $startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
    foreach ($name in @('Voice Type', 'VoiceType', 'voice')) {
        Assert-True (Test-Path -LiteralPath (Join-Path $startMenu "$name.lnk")) "Missing Start Menu alias: $name"
    }
    # A matching filename can belong to a different clone. Preserve it.
    $foreignShortcut = Join-Path $startMenu 'voice.lnk'
    Set-Content -LiteralPath $foreignShortcut -Value '{"Arguments":"another clone"}'
    $global:VoiceTypeTestStartupCommand = "wscript.exe `"$vbs`""
    & (Join-Path $clone 'uninstall.ps1') -ToolsDir $tools
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $tools 'Voice Type.lnk'))) 'Owned shortcut remains.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $startMenu 'Voice Type.lnk'))) 'Owned Start Menu shortcut remains.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $startMenu 'VoiceType.lnk'))) 'Owned Start Menu alias remains.'
    Assert-True (Test-Path -LiteralPath $foreignShortcut) 'Uninstall removed another clone shortcut.'
    Assert-True ($null -eq $global:VoiceTypeTestStartupCommand) 'Owned login entry remains.'
    Assert-True (Test-Path -LiteralPath $settings) 'Uninstall removed settings.'
    $global:VoiceTypeTestStartupCommand = 'wscript.exe "another clone"'
    & (Join-Path $clone 'uninstall.ps1') -ToolsDir $tools
    Assert-True ($global:VoiceTypeTestStartupCommand -eq 'wscript.exe "another clone"') 'Uninstall removed another clone login entry.'
    Write-Host 'PASS: install, reinstall, SkipDeps, shortcut ownership and uninstall.'
} finally {
    Remove-Variable -Name VoiceTypeTestStartupCommand -Scope Global -ErrorAction SilentlyContinue
    $env:OS = $oldOS
    $env:APPDATA = $oldAppData
    $env:SystemRoot = $oldSystemRoot
    if (Test-Path -LiteralPath $TestRoot) { Remove-Item -LiteralPath $TestRoot -Recurse -Force }
}
