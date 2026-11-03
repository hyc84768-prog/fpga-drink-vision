param([string]$TdExe = "D:\anlu\bin\td_commands_prompt.exe")
$ErrorActionPreference = "Stop"

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$SynDir = Join-Path $ProjectRoot "td_project\camera_to_dsi_display_Runs\syn_1"
$PhyDir = Join-Path $ProjectRoot "td_project\camera_to_dsi_display_Runs\phy_1"
$Td = $TdExe

if (!(Test-Path -LiteralPath $Td)) {
    throw "Tang Dynasty executable not found: $Td"
}
if (!(Test-Path -LiteralPath (Join-Path $SynDir "camera_to_dsi_display_gate.db"))) {
    throw "A current synthesis gate database is required: $SynDir\camera_to_dsi_display_gate.db"
}

New-Item -ItemType Directory -Force -Path $PhyDir | Out-Null
Copy-Item -LiteralPath (Join-Path $SynDir "camera_to_dsi_display.prj") -Destination (Join-Path $PhyDir "camera_to_dsi_display.prj") -Force
Copy-Item -LiteralPath (Join-Path $SynDir "camera_to_dsi_display.tcl") `
    -Destination (Join-Path $PhyDir "camera_to_dsi_display.tcl") -Force

# An imported gate DB retains cached user constraints. Reload the current SDC
# before place, while retaining the generated DDR/IP constraints.
$FlowPath = Join-Path $PhyDir 'camera_to_dsi_display.tcl'
$FlowText = Get-Content -LiteralPath $FlowPath -Raw
$FlowText = $FlowText.Replace('### Editable zone for opt_place ###',
    "### Editable zone for opt_place ###`n  clear_user_sdc`n  read_sdc ../../camera_to_dsi_display.sdc")
Set-Content -LiteralPath $FlowPath -Value $FlowText -Encoding ascii

$Settings = @"
# Generated from this project by scripts/run_phy.ps1.
set ADCList {"../../../user_source/constraints_source/pin.adc"}
set IpADCList { ddr2 ../../../user_source/hdl_source/ph1p35_ddr/ddr2/src/adc/ddr2.adc }
set IpSDCList { ddr2 ../../../user_source/hdl_source/ph1p35_ddr/ddr2/src/sdc/ddr2.sdc w128_d512_fifo ../../../user_source/ip_source/w128_d512_fifo/w128_d512_fifo.tcl }
set SDCList {"../../camera_to_dsi_display.sdc"}
set area_option -packarea
set arr_filter false
set device_name ph1_35p.db
set drHoldFix on
set end_step bitgen
set package_name PH1P35MDG324
set parent ../syn_1
set prj_name {camera_to_dsi_display}
set run_type phy
set speed 3
set start_step opt_place
set top_model_name {design_top_wrapper}
"@
Set-Content -LiteralPath (Join-Path $PhyDir "settings.cfg") -Value $Settings -Encoding ascii

Push-Location $PhyDir
try {
    $Started = Get-Date
    & $Td 'camera_to_dsi_display.tcl'
    if ($LASTEXITCODE -ne 0) {
        throw "TD physical implementation failed with exit code $LASTEXITCODE"
    }
    $Bit = Get-Item -LiteralPath (Join-Path $PhyDir 'camera_to_dsi_display.bit')
    if ($Bit.LastWriteTime -lt $Started) { throw 'TD did not produce a fresh bitstream' }
}
finally {
    Pop-Location
}
