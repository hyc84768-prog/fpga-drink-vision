// Stream delay/application topology follows the MiLianKe reference AWB.
// Reference: MiLianKe Electronic Technology, www.milianke.com / www.uisrc.com,
// original AWB author XiaoQingquan, 2024/10. Reference code is for learning.
// Frame-based statistics, neutral selection and manual calibration are custom.
// Frame-start intentionally leads delayed RGB, preserving DDR FIFO reset time.
module awb #(
    parameter IMG_HEIGHT=1080, IMG_WIDTH=1920
)(
    input wire I_clk,I_rst_n,I_tlast,I_tuser,
    input wire [95:0] I_tdata,
    input wire I_tvalid,
    output wire I_tready,O_tlast,O_tuser,
    output wire [95:0] O_tdata,
    output wire O_tvalid,O_gain_updated,O_locked,O_calibration_toggle,
    input wire I_cal_key_n,O_tready,I_cal_request_toggle
);
    wire [19:0] r_gain,b_gain;
    contest_wb_control #(.WIDTH(IMG_WIDTH),.HEIGHT(IMG_HEIGHT)) control(
        .clk(I_clk),.rst_n(I_rst_n),.frame_start(I_tuser),.valid(I_tvalid),.pixels(I_tdata),
        .cal_key_n(I_cal_key_n),.cal_request_toggle(I_cal_request_toggle),.r_gain(r_gain),.b_gain(b_gain),
        .updated(O_gain_updated),.locked(O_locked),.calibration_toggle(O_calibration_toggle));
    reg [95:0] input_d0,input_d1,data_d1;
    reg valid_r0,valid_r1,valid_d1,valid_d2;
    wire [95:0] delayed_data;
    wire delayed_valid;
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin input_d0<=0; input_d1<=0; valid_r0<=0; valid_r1<=0; end
        else begin input_d0<=I_tdata; input_d1<=input_d0; valid_r0<=I_tvalid; valid_r1<=valid_r0; end
    end
    signal_delay #(.IMG_HEIGHT(IMG_HEIGHT),.IMG_WIDTH(IMG_WIDTH),.DATA_WIDTH(96),.DELAY_CYCLE(50)) signal_delay_d(
        .I_clk(I_clk),.I_rst_n(I_rst_n),.I_tuser(I_tuser),.I_valid(valid_r1),.I_data(input_d1),
        .O_valid(delayed_valid),.O_data(delayed_data),.O_tuser());
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin data_d1<=0; valid_d1<=0; valid_d2<=0; end
        else begin data_d1<=delayed_data; valid_d1<=delayed_valid; valid_d2<=valid_d1; end
    end
    genvar lane;
    generate for(lane=0;lane<4;lane=lane+1) begin: gain_lane
        reg [27:0] rp,bp;
        reg [7:0] gp;
        always @(posedge I_clk or negedge I_rst_n) begin
            if(!I_rst_n) begin rp<=0; gp<=0; bp<=0; end
            else if(valid_d1) begin
                rp<=r_gain*data_d1[lane*24+16+:8];
                gp<=data_d1[lane*24+8+:8];
                bp<=b_gain*data_d1[lane*24+:8];
            end
        end
        assign O_tdata[lane*24+:24]=valid_d2 ?
            {(|rp[27:24] ? 8'd255:rp[23:16]),gp,(|bp[27:24] ? 8'd255:bp[23:16])}:24'd0;
    end endgenerate
    assign O_tvalid=valid_d2;
    assign O_tlast=!valid_d1 && valid_d2;
    assign O_tuser=I_tuser;
    assign I_tready=O_tready;
endmodule

module contest_wb_control #(
    parameter integer WIDTH=1280,HEIGHT=720,DEBOUNCE=1000000,MIN_SAMPLES=64
)(
    input wire clk,rst_n,frame_start,valid,cal_key_n,cal_request_toggle,
    input wire [95:0] pixels,
    output reg [19:0] r_gain,b_gain,
    output reg updated,locked,calibration_toggle
);
    // Average all four pixels, not only one Bayer phase/pixel lane.
    wire [9:0] r_sum={2'd0,pixels[23:16]}+{2'd0,pixels[47:40]}+{2'd0,pixels[71:64]}+{2'd0,pixels[95:88]};
    wire [9:0] g_sum={2'd0,pixels[15:8]}+{2'd0,pixels[39:32]}+{2'd0,pixels[63:56]}+{2'd0,pixels[87:80]};
    wire [9:0] b_sum={2'd0,pixels[7:0]}+{2'd0,pixels[31:24]}+{2'd0,pixels[55:48]}+{2'd0,pixels[79:72]};
    reg [7:0] ar,ag,ab;
    reg sampled,in_roi;
    reg [11:0] xpos,ypos;
    wire [7:0] mx=ar>ag ? (ar>ab ? ar:ab):(ag>ab ? ag:ab);
    wire [7:0] mn=ar<ag ? (ar<ab ? ar:ab):(ag<ab ? ag:ab);
    wire [9:0] light={2'd0,ar}+{1'b0,ag,1'b0}+{2'd0,ab};
    // Only sufficiently bright, unsaturated near-neutral samples drive AUTO.
    // A saturated red scene cannot drive its own red gain toward zero.
    wire neutral=mn>=24 && mx<=248 && ({1'b0,mx}<={mn,1'b0}) && light>=256;
    wire calibratable=mn>=12 && mx<=248;
    reg key_meta,key_sync,key_stable,key_latched,cal_pending,capture_cal;
    reg [5:0] cal_frames_left;
    reg [1:0] cal_request_sync;
    reg cal_request_seen;
    reg [19:0] key_count;
    reg [31:0] sum_r,sum_g,sum_b;
    reg [15:0] samples;
    reg busy,manual_div;
    reg [5:0] bits_left;
    reg [47:0] dividend,qr,qb;
    reg [31:0] dr,db;
    reg [32:0] rr,rb;
    wire [32:0] nr={rr[31:0],dividend[47]};
    wire [32:0] nb={rb[31:0],dividend[47]};
    wire take_r=nr>={1'b0,dr},take_b=nb>={1'b0,db};
    wire [47:0] qr_next={qr[46:0],take_r},qb_next={qb[46:0],take_b};
    function [19:0] clamp_gain;
        input [47:0] value;
        begin
            if(value<48'd16384) clamp_gain=20'd16384; // 0.25
            else if(value>48'd262144) clamp_gain=20'd262144; // 4.0
            else clamp_gain=value[19:0];
        end
    endfunction
    function [19:0] approach;
        input [19:0] old_value,new_value;
        begin
            if(new_value>=old_value) approach=old_value+((new_value-old_value+20'd2)>>2);
            else approach=old_value-((old_value-new_value+20'd2)>>2);
        end
    endfunction
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            ar<=0; ag<=0; ab<=0; sampled<=0; in_roi<=0; xpos<=0; ypos<=0;
        end else begin
            sampled<=valid && xpos[5:2]==0;
            ar<=r_sum[9:2]; ag<=g_sum[9:2]; ab<=b_sum[9:2];
            in_roi<=xpos>=WIDTH/4 && xpos<WIDTH*3/4 && ypos>=HEIGHT/4 && ypos<HEIGHT*3/4;
            if(frame_start) begin xpos<=0; ypos<=0; sampled<=0; end
            else if(valid) begin
                if(xpos>=WIDTH-4) begin xpos<=0; ypos<=ypos==HEIGHT-1 ? 0:ypos+1'b1; end
                else xpos<=xpos+12'd4;
            end
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            key_meta<=1; key_sync<=1; key_stable<=1; key_latched<=0;
            key_count<=0; cal_pending<=0; capture_cal<=0;cal_frames_left<=0;cal_request_sync<=0;cal_request_seen<=0;
            sum_r<=1; sum_g<=1; sum_b<=1; samples<=0;
            busy<=0; manual_div<=0; bits_left<=0;
            dividend<=0; qr<=0; qb<=0; dr<=1; db<=1; rr<=0; rb<=0;
            r_gain<=20'd65536; b_gain<=20'd65536; updated<=0; locked<=0; calibration_toggle<=0;
        end else begin
            cal_request_sync<={cal_request_sync[0],cal_request_toggle};
            if(cal_request_sync[1]!=cal_request_seen)begin cal_pending<=1;cal_request_seen<=cal_request_sync[1];end
            key_meta<=cal_key_n; key_sync<=key_meta;
            if(key_sync!=key_stable) begin
                if(key_count==DEBOUNCE-1) begin
                    key_count<=0; key_stable<=key_sync;
                    if(!key_sync && !key_latched) begin cal_pending<=1; key_latched<=1; end
                    else if(key_sync) key_latched<=0;
                end else key_count<=key_count+1'b1;
            end else key_count<=0;
            if(frame_start) begin
                sum_r<=1; sum_g<=1; sum_b<=1; samples<=0;
                // A button can arrive before the white card is steady. Retry
                // at most 30 complete camera frames, never silently forever.
                if(cal_pending) begin
                    cal_pending<=0;capture_cal<=1;cal_frames_left<=30;
                end else if(capture_cal) begin
                    if(cal_frames_left>1)cal_frames_left<=cal_frames_left-1'b1;
                    else begin capture_cal<=0;cal_frames_left<=0;end
                end
                if(!busy && samples>=MIN_SAMPLES && (capture_cal || !locked)) begin
                    dividend<={sum_g,16'd0}; dr<=sum_r; db<=sum_b;
                    qr<=0; qb<=0; rr<=0; rb<=0; bits_left<=48;
                    busy<=1; manual_div<=capture_cal;
                    if(capture_cal)begin capture_cal<=0;cal_frames_left<=0;end
                end
            end else if(sampled && (capture_cal ? (in_roi && calibratable):neutral)) begin
                sum_r<=sum_r+ar; sum_g<=sum_g+ag; sum_b<=sum_b+ab;
                if(samples!=16'hffff) samples<=samples+1'b1;
            end
            if(busy) begin
                dividend<={dividend[46:0],1'b0}; qr<=qr_next; qb<=qb_next;
                rr<=take_r ? nr-{1'b0,dr}:nr;
                rb<=take_b ? nb-{1'b0,db}:nb;
                bits_left<=bits_left-1'b1;
                if(bits_left==1) begin
                    busy<=0; updated<=1;
                    if(manual_div) begin r_gain<=clamp_gain(qr_next); b_gain<=clamp_gain(qb_next); locked<=1; calibration_toggle<=~calibration_toggle; end
                    else begin
                        r_gain<=approach(r_gain,clamp_gain(qr_next));
                        b_gain<=approach(b_gain,clamp_gain(qb_next));
                    end
                end
            end
        end
    end
endmodule
