# Remove only shortcuts and login registration that point to this clone.
param([string]$ToolsDir = 'C:\dev\tools')
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Run uninstall.ps1 on Windows.' }
$vbsPath = Join-Path $PSScriptRoot 'voice-type.vbs'
$wsh = New-Object -ComObject WScript.Shell
$startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
$paths = @((Join-Path $ToolsDir 'Voice Type.lnk'))
foreach ($name in @('Voice Type', 'VoiceType', 'voice')) {
    $paths += Join-Path $startMenu "$name.lnk"
}
foreach ($path in $paths) {
    if (Test-Path -LiteralPath $path) {
        $shortcut = $wsh.CreateShortcut($path)
        if ($shortcut.Arguments -eq "`"$vbsPath`"") {
            Remove-Item -LiteralPath $path
            Write-Host "Removed $path" -ForegroundColor Green
        }
    }
}
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$startup = Get-ItemProperty -LiteralPath $runKey -Name VoiceType -ErrorAction SilentlyContinue
if ($startup -and $startup.VoiceType -eq "wscript.exe `"$vbsPath`"") {
    Remove-ItemProperty -LiteralPath $runKey -Name VoiceType
}
Write-Host 'Shortcuts removed. Exit Voice Type from its tray menu if it is running.'
Write-Host 'Your settings, transcription history and downloaded models are retained.'
