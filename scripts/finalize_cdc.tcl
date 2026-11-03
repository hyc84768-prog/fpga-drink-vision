# Run from td_project/camera_to_dsi_display_Runs/phy_1. Physical routes remain
# unchanged; replace cached user SDC, verify two-flop CDC chains and regenerate.
import_device ph1_35p.db -package PH1P35MDG324 -speed 3
import_db camera_to_dsi_display_pr.db
clear_user_sdc
read_sdc ../../camera_to_dsi_display.sdc
update_timing -mode final
if {[llength [get_regs {u_frame_mailbox/request_sync[0]}]] != 0} {
    foreach q {{u_frame_mailbox/request_sync[0]} {u_frame_mailbox/request_sync[1]} {u_frame_mailbox/ack_sync[0]} {u_frame_mailbox/ack_sync[1]}} {
        if {[llength [get_regs $q]] != 1} { error "Missing mailbox synchronizer: $q" }
    }
    report_timing_path -from [get_regs {u_frame_mailbox/request_sync[0]}] -to [get_regs {u_frame_mailbox/request_sync[1]}] -file ../../../docs/mailbox_req_second_stage_timing.rpt
    report_timing_path -from [get_regs {u_frame_mailbox/ack_sync[0]}] -to [get_regs {u_frame_mailbox/ack_sync[1]}] -file ../../../docs/mailbox_ack_second_stage_timing.rpt
}
report_timing_summary -file final_timing.rpt
if {[llength [get_regs {S_wb_cal_sync[0]}]] != 0} {
    foreach q {{S_wb_cal_sync[0]} {S_wb_cal_sync[1]}} {
        if {[llength [get_regs $q]] != 1} { error "Missing calibration event synchronizer: $q" }
    }
    report_timing_path -from [get_regs {S_wb_cal_sync[0]}] -to [get_regs {S_wb_cal_sync[1]}] -file ../../../docs/wb_cal_second_stage_timing.rpt
}
report_timing_summary -file camera_to_dsi_display_pr.timing
report_timing_exception -file camera_to_dsi_display_exception.timing
#  event and bundled-status second stages remain explicitly timed.
foreach {prefix report} {
    {u_board_io/u_status_mailbox/request_sync} {board_req_second_stage_timing.rpt}
    {u_board_io/u_status_mailbox/ack_sync} {board_ack_second_stage_timing.rpt}
    {u_isp_top/u_awb/control/cal_request_sync} {wb_request_second_stage_timing.rpt}
    {u_contest_ae/hold_sync} {ae_hold_second_stage_timing.rpt}
} {
    set first [format {%s[0]} $prefix]
    set second [format {%s[1]} $prefix]
    if {[llength [get_regs $first]] != 1 || [llength [get_regs $second]] != 1} {
        error "Missing  synchronizer: $prefix"
    }
    report_timing_path -from [get_regs $first] -to [get_regs $second] -file ../../../docs/$report
}
# Bundled status data is held throughout the request/acknowledge handshake.
# Its cross-clock setup paths stay timed despite the qualified hold exception.
# Include every path between these domains, including payload flops whose Q
# nets were renamed to top-level LED outputs during packing. Avoid fragile
# physical aliases and packed-cell wildcards; request entry is explicitly cut.
report_timing_path -from [get_clocks {HDMI_PIXEL_CLK}] -to [get_clocks {sys_clk_50m}] -file ../../../docs/board_payload_setup_timing.rpt
export_sdc -file ../../../docs/effective_constraints.sdc
flow_status -file route_flow.status
export_db camera_to_dsi_display_pr.db
bitgen -bit camera_to_dsi_display.bit
