# Install Voice Type shortcuts from this clone. Compatible with PowerShell 5.1.
param(
    [switch]$SkipDeps,
    [string]$ToolsDir = 'C:\dev\tools'
)

$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Run install.ps1 on Windows.' }
$RepoDir = $PSScriptRoot
if (-not $SkipDeps) { & (Join-Path $RepoDir 'deps.ps1') }

# Settings belong to the user, so upgrading must never replace them.
$settingsPath = Join-Path $RepoDir 'settings.json'
if (-not (Test-Path -LiteralPath $settingsPath)) {
    Copy-Item -LiteralPath (Join-Path $RepoDir 'settings.example.json') -Destination $settingsPath
}
New-Item -ItemType Directory -Path $ToolsDir -Force | Out-Null
$startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
New-Item -ItemType Directory -Path $startMenu -Force | Out-Null
$vbsPath = Join-Path $RepoDir 'voice-type.vbs'
$wsh = New-Object -ComObject WScript.Shell
$shortcutPaths = @((Join-Path $ToolsDir 'Voice Type.lnk'))
foreach ($name in @('Voice Type', 'VoiceType', 'voice')) {
    $shortcutPaths += Join-Path $startMenu "$name.lnk"
}
foreach ($path in $shortcutPaths) {
    $shortcut = $wsh.CreateShortcut($path)
    $shortcut.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
    $shortcut.Arguments = "`"$vbsPath`""
    $shortcut.WorkingDirectory = $RepoDir
    $shortcut.Description = 'Push-to-talk voice typing: hold Right Ctrl to record, release to transcribe and paste'
    $shortcut.IconLocation = '%SystemRoot%\System32\imageres.dll,109'
    $shortcut.Save()
    Write-Host "  [lnk] $path" -ForegroundColor Green
}
# Voice Type has no Explorer verbs. Leave the shared Mike's Tools menu alone.
Write-Host "Right-click 'Voice Type.lnk' in $ToolsDir and pin it to the taskbar." -ForegroundColor Cyan
