param([string]$TdExe = "D:\anlu\bin\td_commands_prompt.exe")
$ErrorActionPreference = "Stop"

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$RunDir = Join-Path $ProjectRoot "td_project\camera_to_dsi_display_Runs\syn_1"
$Td = $TdExe

if (!(Test-Path -LiteralPath $Td)) {
    throw "Tang Dynasty executable not found: $Td"
}
if (!(Test-Path -LiteralPath (Join-Path $RunDir "settings.cfg"))) {
    throw "Synthesis settings not found: $RunDir\settings.cfg"
}

Push-Location $RunDir
try {
    $Started = Get-Date
    # TD expands argv into a Tcl source command without quoting spaces.
    # We already run inside RunDir: a relative script name avoids that bug.
    & $Td 'camera_to_dsi_display.tcl'
    if ($LASTEXITCODE -ne 0) {
        throw "TD synthesis failed with exit code $LASTEXITCODE"
    }
    $Gate = Get-Item -LiteralPath (Join-Path $RunDir 'camera_to_dsi_display_gate.db')
    if ($Gate.LastWriteTime -lt $Started) { throw 'TD did not produce a fresh synthesis database' }
}
finally {
    Pop-Location
}
