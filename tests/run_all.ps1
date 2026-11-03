param([string]$ModelSimExe = "D:\modelsim1\win64\vsim.exe")
$ErrorActionPreference = "Stop"

$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$Vsim = $ModelSimExe
if (!(Test-Path -LiteralPath $Vsim)) {
    throw "ModelSim executable not found: $Vsim"
}

$Vlog = Join-Path (Split-Path $Vsim) 'vlog.exe'
$Vlib = Join-Path (Split-Path $Vsim) 'vlib.exe'
$Rtl = Join-Path $Root 'user_source\hdl_source'
#  learns from the camera only; the replay is synthetic and needs no phone assets.
$Processing = @("$Rtl\contest_display_enhance.v", "$Rtl\contest_label_matcher.v", "$Rtl\contest_ui_control.v", "$Rtl\contest_spatial_filters.v", "$Rtl\contest_histogram_equalizer.v", "$Rtl\bottle_template_store.v", "$Rtl\contest_bottle_classifier.v")
$Runs = @(
    @{ Library = "work_display"; Top = "tb_display_enhance"; Sources = @("$Rtl\contest_spatial_filters.v", "$Rtl\contest_display_enhance.v", "$PSScriptRoot\tb_display_enhance.v") },
    @{ Library = "work_manual"; Top = "tb_bottle_manual"; Sources = @("$Rtl\contest_label_matcher.v", "$Rtl\bottle_template_store.v", "$Rtl\contest_bottle_classifier.v", "$PSScriptRoot\tb_bottle_manual.v") },
    @{ Library = "work_label"; Top = "tb_label_matcher"; Sources = @("$Rtl\contest_label_matcher.v", "$PSScriptRoot\tb_label_matcher.v") },
    @{ Library = "work_ui"; Top = "tb_ui_control"; Sources = @("$Rtl\contest_ui_control.v", "$PSScriptRoot\tb_ui_control.v") },
    @{ Library = "work_board"; Top = "tb_board_io"; Sources = @("$Rtl\contest_board_io.v", "$PSScriptRoot\tb_board_io.v") },
    @{ Library = "work_spatial"; Top = "tb_spatial_filters"; Sources = @("$Rtl\contest_spatial_filters.v", "$PSScriptRoot\tb_spatial_filters.v") },
    @{ Library = "work_histogram"; Top = "tb_histogram_equalizer"; Sources = @("$Rtl\contest_histogram_equalizer.v", "$PSScriptRoot\tb_histogram_equalizer.v") },
    @{ Library = "work_histogram_range"; Top = "tb_histogram_range"; Sources = @("$Rtl\contest_histogram_equalizer.v", "$PSScriptRoot\tb_histogram_range.v") },
    @{ Library = "work_frame_meta"; Top = "tb_frame_mailbox"; Sources = @("$Rtl\contest_frame_mailbox.v", "$PSScriptRoot\tb_frame_mailbox.v") },
    @{ Library = "work_bottle"; Top = "tb_bottle_classifier"; Sources = @("$Rtl\contest_label_matcher.v", "$Rtl\bottle_template_store.v", "$Rtl\contest_bottle_classifier.v", "$PSScriptRoot\tb_bottle_classifier.v") },
    @{ Library = "work_stability"; Top = "tb_bottle_stability"; Sources = @("$Rtl\contest_label_matcher.v", "$Rtl\bottle_template_store.v", "$Rtl\contest_bottle_classifier.v", "$PSScriptRoot\tb_bottle_stability.v") },
    @{ Library = "work_core"; Top = "tb_contest_image_core"; Sources = $Processing + @("$Rtl\contest_image_core.v", "$PSScriptRoot\tb_contest_image_core.v") },
    @{ Library = "work_ae"; Top = "tb_contest_auto_exposure"; Sources = @("$Rtl\contest_auto_exposure.v", "$Rtl\uics520_cfg\SC520GainTbl.v", "$Rtl\uics520_cfg\uics520reg_720p60.v", "$PSScriptRoot\tb_contest_auto_exposure.v") },
    @{ Library = "work_age"; Top = "tb_video_age"; Sources = @("$Rtl\video_in.v", "$PSScriptRoot\tb_video_age.v") },
    @{ Library = "work_wb"; Top = "tb_wb_control"; Sources = @("$Rtl\awb.v", "$PSScriptRoot\tb_wb_control.v") },
    @{ Library = "work_wb_stream"; Top = "tb_awb_stream"; Sources = @("$Rtl\awb.v", "$PSScriptRoot\tb_awb_stream.v") },
    @{ Library = "work_bayer"; Top = "tb_bayer_color"; Sources = @("$Rtl\isp\demosaic_4x_2_0\bilinear_interpolation.v", "$PSScriptRoot\tb_bayer_color.v") },
    @{ Library = "work_buzzer"; Top = "tb_contest_buzzer"; Sources = @("$Rtl\contest_image_core.v", "$PSScriptRoot\tb_contest_buzzer.v") },
    @{ Library = "work_algorithm_video"; Top = "tb_algorithm_video"; Sources = $Processing + @("$Rtl\contest_image_core.v", "$Rtl\hdmi_mixer.v", "$Rtl\anlogic_logo_rom.v", "$Rtl\contest_anniversary_rom.v", "$Rtl\osd_char_lib.v", "$PSScriptRoot\tb_algorithm_video.v") },
    @{ Library = "work_mixer"; Top = "tb_hdmi_mixer"; Sources = $Processing + @("$Rtl\contest_image_core.v", "$Rtl\hdmi_mixer.v", "$Rtl\anlogic_logo_rom.v", "$Rtl\contest_anniversary_rom.v", "$Rtl\osd_char_lib.v", "$PSScriptRoot\tb_hdmi_mixer.v") },
    @{ Library = "work_replay"; Top = "tb_bottle_replay"; Sources = $Processing + @("$Rtl\contest_image_core.v", "$Rtl\hdmi_mixer.v", "$Rtl\anlogic_logo_rom.v", "$Rtl\contest_anniversary_rom.v", "$Rtl\osd_char_lib.v", "$PSScriptRoot\tb_bottle_replay.v") }
)

foreach ($Run in $Runs) {
    Push-Location $PSScriptRoot
    try {
        if (!(Test-Path -LiteralPath $Run.Library)) {
            & $Vlib $Run.Library
            if ($LASTEXITCODE -ne 0) { throw "Cannot create library" }
        }
        & $Vlog -work $Run.Library @($Run.Sources)
        if ($LASTEXITCODE -ne 0) { throw "Compilation failed: $($Run.Top)" }
        $Log = & $Vsim -c -lib $Run.Library -do "run -all; quit -f" $Run.Top 2>&1
        $SimExit = $LASTEXITCODE
        $Log | Tee-Object -FilePath (Join-Path $PSScriptRoot "$($Run.Top).log")
        if ($SimExit -ne 0 -or ($Log -match 'FAIL|Fatal:|Error:') -or !($Log -match '# PASS ')) {
            throw "Simulation failed: $($Run.Top)"
        }
    }
    finally {
        Pop-Location
    }
}
