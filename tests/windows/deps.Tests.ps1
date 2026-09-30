# Fake Python to exercise deps.ps1's per-package install logic without
# network access or a real interpreter. llama-cpp-python has no prebuilt
# PyPI wheel, so it fails to build on machines without a C/C++ compiler.
# It only backs the optional, off-by-default formatter, so that failure
# must warn and continue rather than aborting the whole install.
$ErrorActionPreference = 'Stop'
$deps = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'deps.ps1'

$state = @{ Installed = @(); Failing = @() }

function python {
    if ($args[0] -eq '-c') {
        # import probe: "import <module>" -> succeed only if already installed
        $module = ($args[1] -split ' ')[1]
        $global:LASTEXITCODE = $(if ($state.Installed -contains $module) { 0 } else { 1 })
        return
    }
    if ($args[0] -eq '-m' -and $args[1] -eq 'pip') {
        $package = $args[3]
        if ($state.Failing -contains $package) {
            $global:LASTEXITCODE = 1
        } else {
            $state.Installed += $package
            $global:LASTEXITCODE = 0
        }
        return
    }
    $global:LASTEXITCODE = 0
}

function Assert-True($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

# A required package failing to install must still stop the installer.
$state.Installed = @()
$state.Failing = @('faster-whisper')
$threw = $false
try { & $deps *> $null } catch { $threw = $true }
Assert-True $threw 'A required package failing to install must throw.'

# llama-cpp-python failing to install must NOT stop the installer, since the
# formatter it backs is optional and off by default.
$state.Installed = @()
$state.Failing = @('llama-cpp-python')
$threw = $false
try { $output = & $deps *>&1 } catch { $threw = $true }
$global:LASTEXITCODE = 0
Assert-True (-not $threw) 'llama-cpp-python failing must not fail the deps script.'
Assert-True (($output -join "`n") -match 'llama-cpp-python') 'Expected a message naming the skipped optional package.'
Assert-True ($state.Installed -notcontains 'llama-cpp-python') 'llama-cpp-python should not be recorded as installed when it fails.'

# Everything succeeding installs every package, including the optional one.
$state.Installed = @()
$state.Failing = @()
& $deps *> $null
Assert-True ($state.Installed -contains 'llama-cpp-python') 'llama-cpp-python should still be installed when it succeeds.'

$global:LASTEXITCODE = 0
Write-Host 'PASS: voice-type dependency setup tests'
