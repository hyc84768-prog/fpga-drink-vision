param([string]$TdExe='D:\anlu\bin\td_commands_prompt.exe')
$ErrorActionPreference='Stop'
$ProjectRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Phy=Join-Path $ProjectRoot 'td_project/camera_to_dsi_display_Runs/phy_1'
Push-Location $Phy
try {
    & $TdExe '../../../scripts/finalize_cdc.tcl'
    if($LASTEXITCODE -ne 0){throw 'Routed signoff failed'}
} finally {Pop-Location}
