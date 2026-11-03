create_clock -name {sys_clk_50m} -period 20.000 -waveform {0.000 10.000} [get_ports {I_sys_clk}]
create_clock -name {mipi_rx_ck_pad} -period 2.415 -waveform {0.000 1.208} [get_nets {IO_rx_clk_pad_p}]

derive_clocks

rename_clock -name {pll_clk_100m} [get_clocks {u_PLL/ph1p_phy_pll_wrapper_25a56e5ce2f9_Inst/u_PH1P_PHY_PLL.clkc[0]}]
rename_clock -name {pll_clk_24m} [get_clocks {u_PLL/ph1p_phy_pll_wrapper_25a56e5ce2f9_Inst/u_PH1P_PHY_PLL.clkc[1]}]
rename_clock -name {HDMI_PIXEL_CLK} [get_clocks {u_PLL/ph1p_phy_pll_wrapper_25a56e5ce2f9_Inst/u_PH1P_PHY_PLL.clkc[4]}]
rename_clock -name {HDMI_SERIAL_CLK} [get_clocks {u_PLL/ph1p_phy_pll_wrapper_25a56e5ce2f9_Inst/u_PH1P_PHY_PLL.clkc[5]}]

rename_clock -name {MIPI_RX_BYTE_CLK} [get_clocks {u_mipi_dphy_rx_ph1p_mipiio_wrapper/u_ph1p_mipiio_rx_wrapper/u_PH1P_LOGIC_DPHY_MIPI_RX.o_fabric_div4_8_clk}]


set_clock_groups -asynchronous \
    -group [get_clocks {mipi_rx_ck_pad MIPI_RX_BYTE_CLK}] \
    -group [get_clocks {sys_clk_50m pll_clk_100m pll_clk_24m HDMI_PIXEL_CLK HDMI_SERIAL_CLK}] \
    -group [get_clocks {u_ph1p35_324_ddr_wrapper/u_ddr2/ddr_clk u_ph1p35_324_ddr_wrapper/u_ddr2/usr_clk}]

# Single-bit level CDC into the FIRST register only. The [0] Q-net names
# identify logical registers even after two flops are packed into one slice.
# Stage [0] -> [1] remains timed at the destination clock; do not cut it.
# Its unused level synchronizer is optimized away; no exception remains for it.

# continuously sampled bus. Cut only each single-bit FIRST synchronizer stage.
# Both synchronizer second stages remain timed at their destination clock.
set_false_path -from [get_clocks {HDMI_PIXEL_CLK}] -to [get_regs {u_board_io/u_status_mailbox/request_sync[0]}]
set_false_path -from [get_clocks {sys_clk_50m}] -to [get_regs {u_board_io/u_status_mailbox/ack_sync[0]}]

# held[] changes with request, then stays unchanged until the acknowledgement
# returns through two source flops. dest_data[] captures only after two request
# flops, request detection, and an extra settling cycle (>= 3 full 50 MHz cycles
# after launch). A same-edge hold check across these clocks is inapplicable.
# Remove ONLY that hold check for this specific bundled bus; keep its existing
# cross-clock setup checks, which bound every data route to < one 20 ns period.
# Constrain through the held DATA nets, qualified by both clock domains.
# This survives output-Q aliasing (LED bits 41/42) without a packed-cell
# wildcard that could also exempt a neighbouring flop's local hold paths.
set_false_path -hold -from [get_clocks {HDMI_PIXEL_CLK}] -through [get_nets {u_board_io/u_status_mailbox/held*}] -to [get_clocks {sys_clk_50m}]
