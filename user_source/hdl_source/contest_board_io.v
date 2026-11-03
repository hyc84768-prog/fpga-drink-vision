// board feedback. One coherent held-data mailbox feeds the 50 MHz
// display/audio domain; event bits are toggles, never unsynchronized pulses.
module contest_board_io #(
    parameter integer CLOCK_HZ=50000000,
    parameter integer SCAN_SLOT_US=1000, BLANK_US=20,
    parameter integer HEARTBEAT_MS=500, ERROR_BLINK_MS=250,
    parameter integer DRINK_MS=100, LEARN_ON_MS=40, LEARN_GAP_MS=40,
    parameter integer TONE_HZ=2000,
    parameter integer SEG_ACTIVE_LOW=1, SEL_ACTIVE_LOW=1
)(
    input wire source_clk,clk,rst_n,submit,
    input wire [63:0] status_payload,
    output reg [3:0] leds,
    output wire [7:0] seg_n,sel_n,
    output wire buzzer_n
);
    wire [63:0] board_status;
    contest_status_mailbox #(.WIDTH(64)) u_status_mailbox(
        .source_clk(source_clk),.dest_clk(clk),.rst_n(rst_n),.submit(submit),
        .source_data(status_payload),.dest_data(board_status));

    localparam integer US_CYCLES=CLOCK_HZ/1000000<1 ? 1:CLOCK_HZ/1000000;
    localparam integer US_WIDTH=US_CYCLES<2 ? 1:$clog2(US_CYCLES);
    localparam integer SLOT_WIDTH=SCAN_SLOT_US<2 ? 1:$clog2(SCAN_SLOT_US);
    localparam integer HEART_WIDTH=HEARTBEAT_MS<2 ? 1:$clog2(HEARTBEAT_MS);
    localparam integer ERROR_WIDTH=ERROR_BLINK_MS<2 ? 1:$clog2(ERROR_BLINK_MS);
    localparam integer HALF_PERIOD=CLOCK_HZ/(2*TONE_HZ)<1 ? 1:CLOCK_HZ/(2*TONE_HZ);
    localparam integer TONE_WIDTH=HALF_PERIOD<2 ? 1:$clog2(HALF_PERIOD);
    reg [US_WIDTH-1:0] us_divider;
    reg [9:0] ms_divider;
    wire us_tick=us_divider==US_CYCLES-1;
    wire ms_tick=us_tick && ms_divider==999;
    reg [SLOT_WIDTH-1:0] scan_us_count;
    reg [2:0] scan_index;
    reg [31:0] scan_digits;
    reg [7:0] scan_dp;
    reg [HEART_WIDTH-1:0] heart_count;
    reg [ERROR_WIDTH-1:0] error_count;
    reg heartbeat,error_phase;
    reg seen_drink,seen_learn;
    reg [15:0] drink_remaining,learn_remaining;
    reg [1:0] learn_phase;
    wire new_drink=board_status[46]!=seen_drink;
    wire new_learn=board_status[47]!=seen_learn;
    wire muted=board_status[44];
    wire envelope_active=learn_phase!=0 ? (learn_phase==1 || learn_phase==3):
        drink_remaining!=0 ? 1'b1:board_status[45];
    reg [TONE_WIDTH-1:0] tone_count;
    reg tone_phase;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            us_divider<=0;ms_divider<=0;scan_us_count<=0;scan_index<=0;
            scan_digits<=32'hffffffff;scan_dp<=0;
            heart_count<=0;error_count<=0;heartbeat<=0;error_phase<=0;
            seen_drink<=0;seen_learn<=0;drink_remaining<=0;learn_remaining<=0;learn_phase<=0;
            tone_count<=0;tone_phase<=0;
        end else begin
            if(us_tick) begin
                us_divider<=0;
                ms_divider<=ms_divider==999 ? 10'd0:ms_divider+1'b1;
                if(scan_us_count==SCAN_SLOT_US-1) begin
                    scan_us_count<=0;scan_index<=scan_index+1'b1;
                    // Publish all eight digits together only at scan-frame start.
                    if(scan_index==7) begin scan_digits<=board_status[31:0];scan_dp<=board_status[39:32];end
                end else scan_us_count<=scan_us_count+1'b1;
            end else us_divider<=us_divider+1'b1;
            if(ms_tick) begin
                if(heart_count==HEARTBEAT_MS-1) begin heart_count<=0;heartbeat<=~heartbeat;end
                else heart_count<=heart_count+1'b1;
                if(error_count==ERROR_BLINK_MS-1) begin error_count<=0;error_phase<=~error_phase;end
                else error_count<=error_count+1'b1;
            end
            // Always consume toggles, including while muted, so unmuting never
            // replays an old notification. Learning has priority over recognition.
            seen_drink<=board_status[46];seen_learn<=board_status[47];
            if(muted) begin drink_remaining<=0;learn_remaining<=0;learn_phase<=0;end
            else if(new_learn) begin
                learn_phase<=1;learn_remaining<=LEARN_ON_MS;drink_remaining<=0;
            end else begin
                if(new_drink && learn_phase==0) drink_remaining<=DRINK_MS;
                else if(ms_tick && drink_remaining!=0) drink_remaining<=drink_remaining-1'b1;
                if(ms_tick && learn_phase!=0) begin
                    if(learn_remaining>1) learn_remaining<=learn_remaining-1'b1;
                    else case(learn_phase)
                        1:begin learn_phase<=2;learn_remaining<=LEARN_GAP_MS;end
                        2:begin learn_phase<=3;learn_remaining<=LEARN_ON_MS;end
                        default:begin learn_phase<=0;learn_remaining<=0;end
                    endcase
                end
            end
            if(muted || !envelope_active) begin tone_count<=0;tone_phase<=0;end
            else if(tone_count==HALF_PERIOD-1) begin tone_count<=0;tone_phase<=~tone_phase;end
            else tone_count<=tone_count+1'b1;
        end
    end
    assign buzzer_n=muted || !envelope_active ? 1'b1:~tone_phase;
    always @(*) begin
        leds=board_status[43:40];leds[0]=heartbeat;
        if(board_status[48]) leds[3]=error_phase;
    end
    function [6:0] segments;
        input [3:0] code;
        begin case(code)
            0:segments=7'h3f;1:segments=7'h06;2:segments=7'h5b;3:segments=7'h4f;
            4:segments=7'h66;5:segments=7'h6d;6:segments=7'h7d;7:segments=7'h07;
            8:segments=7'h7f;9:segments=7'h6f;10:segments=7'h40;11:segments=7'h39;
            12:segments=7'h7c;13:segments=7'h79;14:segments=7'h71;default:segments=0;
        endcase end
    endfunction
    wire [3:0] digit=scan_digits >> ((7-scan_index)*4);
    wire [7:0] segments_on={scan_dp[7-scan_index],segments(digit)};
    wire [7:0] selected=scan_us_count<BLANK_US ? 8'd0:(8'b1<<scan_index);
    assign seg_n=SEG_ACTIVE_LOW ? ~segments_on:segments_on;
    assign sel_n=SEL_ACTIVE_LOW ? ~selected:selected;
endmodule

// Generic bundled-data handshake. Source data is sampled one source clock
// after submit, so a VS-boundary UI update is included in that frame's payload.
module contest_status_mailbox #(parameter integer WIDTH=64)(
    input wire source_clk,dest_clk,rst_n,submit,
    input wire [WIDTH-1:0] source_data,
    output reg [WIDTH-1:0] dest_data
);
    reg submit_d,request,acknowledge,settling;
    reg [WIDTH-1:0] held;
    reg [1:0] ack_sync,request_sync;
    always @(posedge source_clk or negedge rst_n) begin
        if(!rst_n) begin submit_d<=0;request<=0;held<=0;ack_sync<=0;end
        else begin
            submit_d<=submit;ack_sync<={ack_sync[0],acknowledge};
            if(submit_d && ack_sync[1]==request) begin held<=source_data;request<=~request;end
        end
    end
    always @(posedge dest_clk or negedge rst_n) begin
        if(!rst_n) begin request_sync<=0;acknowledge<=0;settling<=0;dest_data<=0;end
        else begin
            request_sync<={request_sync[0],request};
            if(settling) begin dest_data<=held;acknowledge<=request_sync[1];settling<=0;end
            else if(request_sync[1]!=acknowledge) settling<=1;
        end
    end
endmodule
