// aligned RGB central-ROI metering; bounded exposure/gain per frame.
// Request/ack holds the data bus stable across the camera/24 MHz domains.
module contest_auto_exposure #(
    parameter integer WIDTH=1280,HEIGHT=720,MIN_SAMPLES=32
)(
    input wire camera_clk, input wire cfg_clk, input wire rst_n,
    input wire frame_start, input wire valid, input wire [95:0] pixels,
    input wire camera_configured, input wire write_complete,
    output reg request, output reg [15:0] exposure,
    output reg [15:0] gain, output reg adjustment_seen,
    input wire exposure_hold, output wire hold_active
);
    localparam [15:0] MIN_EXPOSURE = 16'd64, MAX_EXPOSURE = 16'd1991;
    reg [11:0] xpos,ypos;
    reg [19:0] brightness_sum;
    reg [10:0] samples;
    // Match the active 720p sensor table: 0x3e01=7c, 0x3e02=70.
    reg [15:0] desired;
    reg [15:0] desired_gain,offered_gain,gain_meta,gain_sync;
    reg offer_toggle, ack_meta, ack_sync;
    reg [1:0] hold_sync;
    reg [15:0] offered;
    reg offer_meta, offer_sync, offer_seen;
    reg [15:0] data_meta, data_sync;
    reg ack_toggle;
    reg write_pending, write_started;
    wire [11:0] intensity =
        {4'd0,pixels[23:16]}+{3'd0,pixels[15:8],1'b0}+{4'd0,pixels[7:0]}+
        {4'd0,pixels[47:40]}+{3'd0,pixels[39:32],1'b0}+{4'd0,pixels[31:24]}+
        {4'd0,pixels[71:64]}+{3'd0,pixels[63:56],1'b0}+{4'd0,pixels[55:48]}+
        {4'd0,pixels[95:88]}+{3'd0,pixels[87:80],1'b0}+{4'd0,pixels[79:72]};
    wire meter_sample=xpos>=WIDTH/4 && xpos<WIDTH*3/4 &&
        ypos>=HEIGHT/4 && ypos<HEIGHT*3/4 && xpos[4:2]==0 && ypos[2:0]==0;
    wire too_bright=brightness_sum>samples*8'd136;
    wire too_dark=brightness_sum<samples*8'd104;
    wire extreme=brightness_sum>samples*8'd192 || brightness_sum<samples*8'd64;
    wire moderate=brightness_sum>samples*8'd160 || brightness_sum<samples*8'd88;
    wire [15:0] step=extreme ? 16'd128:moderate ? 16'd64:16'd16;
    wire [15:0] lower=desired>MIN_EXPOSURE+step ? desired-step:MIN_EXPOSURE;
    wire [15:0] higher=desired<MAX_EXPOSURE-step ? desired+step:MAX_EXPOSURE;
    // A hold becomes active only when the last already-offered write is acked.
    // Do not cancel an I2C transaction half way through changing exposure.
    assign hold_active = hold_sync[1] && ack_sync == offer_toggle;
    always @(posedge camera_clk or negedge rst_n) begin
        if (!rst_n) begin
            xpos<=0;ypos<=0;brightness_sum <= 0; samples <= 0;
            desired <= MAX_EXPOSURE; offered <= MAX_EXPOSURE;
            desired_gain<=16;offered_gain<=16;
            offer_toggle <= 0; ack_meta <= 0; ack_sync <= 0; hold_sync<=0;
        end else begin
            ack_meta <= ack_toggle;
            ack_sync <= ack_meta;
            hold_sync <= {hold_sync[0], exposure_hold};
            if (valid) begin
                if(xpos>=WIDTH-4)begin xpos<=0;ypos<=ypos==HEIGHT-1 ? 0:ypos+1'b1;end
                else xpos<=xpos+12'd4;
                if (meter_sample && samples < 11'd2047) begin
                    brightness_sum <= brightness_sum + intensity[11:4];
                    samples <= samples + 1'b1;
                end
            end
            if (frame_start) begin
                xpos<=0;ypos<=0;brightness_sum <= 0; samples <= 0;
                if (!hold_sync[1] && samples >= MIN_SAMPLES && ack_sync == offer_toggle) begin
                    // Shed noise-amplifying gain first when bright. In dark
                    // scenes, extend exposure first, then use at most 4x gain.
                    if(too_bright && desired_gain>16)begin
                        desired_gain<=desired_gain-4;offered_gain<=desired_gain-4;
                        offered<=desired;offer_toggle<=~offer_toggle;
                    end else if (too_bright && desired > MIN_EXPOSURE) begin
                        desired <= lower;
                        offered <= lower;
                        offered_gain<=desired_gain;
                        offer_toggle <= ~offer_toggle;
                    end else if (too_dark && desired < MAX_EXPOSURE) begin
                        desired <= higher;
                        offered <= higher;
                        offered_gain<=desired_gain;
                        offer_toggle <= ~offer_toggle;
                    end else if(too_dark && desired_gain<80)begin
                        desired_gain<=desired_gain+4;offered_gain<=desired_gain+4;
                        offered<=desired;offer_toggle<=~offer_toggle;
                    end
                end
            end
        end
    end
    always @(posedge cfg_clk or negedge rst_n) begin
        if (!rst_n) begin
            offer_meta <= 0; offer_sync <= 0; offer_seen <= 0;
            data_meta <= MAX_EXPOSURE; data_sync <= MAX_EXPOSURE;
            ack_toggle <= 0; request <= 0; exposure <= MAX_EXPOSURE;
            gain<=16;gain_meta<=16;gain_sync<=16;
            write_pending <= 0; write_started <= 0;
            adjustment_seen <= 0;
        end else begin
            offer_meta <= offer_toggle;
            offer_sync <= offer_meta;
            data_meta <= offered;
            data_sync <= data_meta;
            gain_meta<=offered_gain;gain_sync<=gain_meta;
            request <= 0;
            if (write_pending) begin
                if (!write_complete) write_started <= 1;
                if (write_started && write_complete) begin
                    write_pending <= 0;
                    write_started <= 0;
                    ack_toggle <= offer_seen;
                    adjustment_seen <= 1;
                end
            end else if (offer_sync != offer_seen && camera_configured && write_complete) begin
                exposure <= data_sync;
                gain<=gain_sync;
                request <= 1;
                offer_seen <= offer_sync;
                write_pending <= 1;
            end
        end
    end
endmodule
