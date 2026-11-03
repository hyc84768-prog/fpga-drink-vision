`timescale 1ns/1ps
module tb_board_io;
    reg source_clk=0,clk=0,rst_n=0,submit=0;
    reg [63:0] payload=0;
    wire [3:0] leds,leds_high;
    wire [7:0] seg,sel,seg_high,sel_high;
    wire buzzer,buzzer_high;
    integer i,n,slot,low_count,phase_cycles,previous_phase,phase_changes=0,checked_digits=0;
    integer selected_count,bit_index;
    reg [3:0] previous_leds;
    reg mailbox_submit=0;
    reg [63:0] mailbox_source=0;
    wire [63:0] mailbox_destination;
    reg [63:0] previous_destination=0;
    always #7 source_clk=~source_clk;
    always #5 clk=~clk;
    contest_board_io #(.CLOCK_HZ(1000000),.SCAN_SLOT_US(20),.BLANK_US(2),
        .HEARTBEAT_MS(2),.ERROR_BLINK_MS(1),.DRINK_MS(4),.LEARN_ON_MS(2),.LEARN_GAP_MS(1),.TONE_HZ(100000)) dut(
        .source_clk(source_clk),.clk(clk),.rst_n(rst_n),.submit(submit),.status_payload(payload),
        .leds(leds),.seg_n(seg),.sel_n(sel),.buzzer_n(buzzer));
    contest_board_io #(.CLOCK_HZ(1000000),.SCAN_SLOT_US(20),.BLANK_US(2),
        .HEARTBEAT_MS(2),.ERROR_BLINK_MS(1),.DRINK_MS(4),.LEARN_ON_MS(2),.LEARN_GAP_MS(1),.TONE_HZ(100000),
        .SEG_ACTIVE_LOW(0),.SEL_ACTIVE_LOW(0)) high_polarity(
        .source_clk(source_clk),.clk(clk),.rst_n(rst_n),.submit(submit),.status_payload(payload),
        .leds(leds_high),.seg_n(seg_high),.sel_n(sel_high),.buzzer_n(buzzer_high));
    contest_status_mailbox #(.WIDTH(64)) mb(
        .source_clk(source_clk),.dest_clk(clk),.rst_n(rst_n),.submit(mailbox_submit),
        .source_data(mailbox_source),.dest_data(mailbox_destination));
    task tick;begin @(posedge clk);#1;end endtask
    task send;
        begin @(negedge source_clk);submit=1;@(negedge source_clk);submit=0;repeat(24)tick;end
    endtask
    function [7:0] golden_segment;
        input integer value;
        begin case(value)
            0:golden_segment=8'hc0;1:golden_segment=8'hf9;2:golden_segment=8'ha4;3:golden_segment=8'hb0;
            4:golden_segment=8'h99;5:golden_segment=8'h92;6:golden_segment=8'h82;7:golden_segment=8'hf8;
            default:golden_segment=8'hff;
        endcase end
    endfunction
    always @(posedge clk)if(rst_n)begin
        #2;
        if(seg_high!==~seg || sel_high!==~sel || leds_high!==leds || buzzer_high!==buzzer)
            $fatal(1,"display polarity parameter changed logical behavior");
        selected_count=0;
        for(bit_index=0;bit_index<8;bit_index=bit_index+1)if(!sel[bit_index])selected_count=selected_count+1;
        if(selected_count>1)$fatal(1,"multiple digits selected");
        if(dut.scan_us_count<2 && sel!==8'hff)$fatal(1,"scan blanking missing");
        if(mailbox_destination!==previous_destination)begin
            if(mailbox_destination!=0 && mailbox_destination[63:32]!==~mailbox_destination[31:0])
                $fatal(1,"torn mailbox data %h",mailbox_destination);
            previous_destination=mailbox_destination;
        end
    end
    initial begin
        repeat(5)tick;@(negedge clk);rst_n=1;
        payload[31:0]=32'h01234567;payload[39:32]=8'h80;payload[43:40]=4'b0110;
        send;repeat(200)tick;
        for(i=0;i<320;i=i+1)begin
            tick;
            if(sel!=8'hff)begin
                slot=0;for(n=0;n<8;n=n+1)if(!sel[n])slot=n;
                if(seg!==(golden_segment(slot) & (slot==0 ? 8'h7f:8'hff)))
                    $fatal(1,"digit/decimal-point/order mismatch slot%0d seg%h",slot,seg);
                checked_digits=checked_digits | (1<<slot);
            end
        end
        if(checked_digits!=255 || leds[2:1]!=2'b11)$fatal(1,"display/LED coverage missing");
        previous_leds=leds;repeat(2200)tick;
        if(leds[0]==previous_leds[0])$fatal(1,"heartbeat did not toggle");
        // Captures data updated on the VS edge, then holds a coherent word even
        // while the source changes during the request/ack settling interval.
        @(negedge source_clk);mailbox_source=64'hfffffff10000000e;mailbox_submit=1;
        @(posedge source_clk);#1;mailbox_source=64'h12345678edcba987;
        @(negedge source_clk);mailbox_submit=0;
        repeat(20)tick;
        if(mailbox_destination!==64'h12345678edcba987)$fatal(1,"mailbox did not capture delayed VS data");
        for(i=0;i<30;i=i+1)begin
            @(negedge source_clk);mailbox_source={~i[31:0],i[31:0]};mailbox_submit=1;
            @(negedge source_clk);mailbox_submit=0;
            repeat(i%5+1)tick;
        end
        repeat(30)tick;
        payload[46]=1;send;
        if(dut.drink_remaining==0)$fatal(1,"drink notification lost across clock domains");
        n=0;low_count=0;
        while(dut.drink_remaining!=0 && n<4500)begin tick;n=n+1;if(!buzzer)low_count=low_count+1;end
        if(n<2900 || n>4000 || low_count<1400 || low_count>2050)$fatal(1,"drink pulse duration/duty %0d %0d",n,low_count);
        repeat(1800)begin tick;if(!buzzer)$fatal(1,"same drink toggle sounded again");end
        payload[45]=1;payload[47]=1;send;
        if(dut.learn_phase!=1)$fatal(1,"learn notification lost");
        previous_phase=1;phase_changes=0;low_count=0;
        for(i=0;i<5500;i=i+1)begin
            tick;
            if(dut.learn_phase==2 && !buzzer)$fatal(1,"red alarm filled learning double-beep gap");
            if(dut.learn_phase!=previous_phase)begin
                case(phase_changes)
                    0:if(dut.learn_phase!=2)$fatal(1,"first learning beep phase");
                    1:if(dut.learn_phase!=3)$fatal(1,"second learning beep phase");
                    2:if(dut.learn_phase!=0)$fatal(1,"learning beep did not finish");
                    default:$fatal(1,"learning event repeated");
                endcase
                phase_changes=phase_changes+1;previous_phase=dut.learn_phase;
            end
            if(dut.learn_phase==0 && !buzzer)low_count=low_count+1;
        end
        if(phase_changes!=3 || low_count<100)$fatal(1,"learning pattern or red-tone resume missing");
        payload[44]=1;payload[46]=0;send;
        repeat(2000)begin tick;if(!buzzer || dut.learn_phase!=0 || dut.drink_remaining!=0)$fatal(1,"mute failed");end
        payload[45]=0;payload[44]=0;send;
        repeat(2500)begin tick;if(!buzzer)$fatal(1,"unmute replayed old notification");end
        payload[48]=1;send;previous_leds=leds;n=0;
        repeat(1500)begin tick;if(leds[3]!=previous_leds[3])n=n+1;end
        if(n==0)$fatal(1,"error LED did not blink");
        $display("PASS board coherent CDC, delayed VS payload, eight-digit order/DP/blanking/polarity, LED feedback, one-shot/double beeps, alarm priority and mute consumption");$finish;
    end
    initial begin #1000000;$fatal(1,"watchdog");end
endmodule
