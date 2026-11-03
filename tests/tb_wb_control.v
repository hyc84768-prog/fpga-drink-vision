`timescale 1ns/1ps
module tb_wb_control;
    reg clk=0,rst_n=0,frame_start=0,valid=0,key_n=1;
    reg [95:0] pixels=0;
    reg menu_request_toggle=0;
    wire [19:0] rg,bg;
    wire updated,locked,calibration_toggle;
    reg old_toggle;
    integer i,row,col;
    reg [19:0] saved_r,saved_b;
    always #5 clk=~clk;
    contest_wb_control #(.WIDTH(128),.HEIGHT(64),.DEBOUNCE(3),.MIN_SAMPLES(8)) dut(
        .clk(clk),.rst_n(rst_n),.frame_start(frame_start),.valid(valid),.pixels(pixels),
        .cal_key_n(key_n),.cal_request_toggle(menu_request_toggle),.r_gain(rg),.b_gain(bg),.updated(updated),.locked(locked),.calibration_toggle(calibration_toggle));
    task tick; begin @(posedge clk); #1; end endtask
    task check; input good; input [511:0] msg;
        begin if(good!==1'b1) begin $display("FAIL %0s",msg); $fatal(1); end end
    endtask
    task paint; input [23:0] color;
        begin
            @(negedge clk); valid=0; frame_start=1; tick;
            @(negedge clk); frame_start=0;
            // Full blanking lets the once-per-frame iterative ratio finish.
            repeat(80) tick;
            for(row=0;row<64;row=row+1) begin
                for(col=0;col<32;col=col+1) begin
                    @(negedge clk); valid=1; pixels={4{color}}; tick;
                end
                @(negedge clk); valid=0; repeat(4) tick;
            end
        end
    endtask
    task cal_press; begin
        //  menu notification, independent of the retired physical key.
        @(negedge clk);menu_request_toggle=~menu_request_toggle;repeat(8)tick;
        check(key_n,"menu calibration never presses the physical KEY2 input");
    end endtask
    initial begin
        repeat(3) tick; @(negedge clk); rst_n=1;
        paint(24'h000000); paint(24'h000000);
        check(rg==65536 && bg==65536 && !updated,"dark startup does not produce invalid gain");
        for(i=0;i<8;i=i+1) paint(24'h5078a0); // cool neutral: 80,120,160
        check(rg>90000 && bg<52000 && updated && !locked,"AUTO corrects cool neutral toward green reference");
        paint(24'hb02020); paint(24'hb02020);
        saved_r=rg; saved_b=bg;
        for(i=0;i<8;i=i+1) paint(24'hb02020);
        check(rg==saved_r && bg==saved_b,"red-dominant frames cannot neutralize their own red channel");
        check(!calibration_toggle,"AUTO never emits manual calibration epoch");
        cal_press;
        paint(24'h5078a0); paint(24'h5078a0);
        check(calibration_toggle,"successful white calibration toggles epoch");
        check(locked && rg>98250 && rg<98340 && bg>49120 && bg<49190,"white-paper ROI calibrates and locks Q16 gains");
        check(((80*rg)>>16)>=119 && ((80*rg)>>16)<=120 && ((160*bg)>>16)>=119 && ((160*bg)>>16)<=120,
              "calibrated white has balanced RGB");
        saved_r=rg; saved_b=bg;
        for(i=0;i<4;i=i+1) paint(24'h2020c0);
        check(rg==saved_r && bg==saved_b,"manual hold remains stable under saturated blue scenes");
        // Manual calibration is a known white reference, so stronger casts
        // rejected by AUTO can still be corrected without guessing the hue.
        old_toggle=calibration_toggle;
        cal_press; paint(24'h2878c8); paint(24'h2878c8);
        check(calibration_toggle!=old_toggle,"repeat successful calibration emits event");
        check(rg>196400 && rg<196700 && bg>39290 && bg<39360,"strong cool white can be manually calibrated");
        cal_press; paint(24'ha07850); paint(24'ha07850);
        check(rg>49120 && rg<49190 && bg>98250 && bg<98340,"repeat calibration adapts to warmer illumination");
        saved_r=rg; saved_b=bg;
        old_toggle=calibration_toggle;
        cal_press; paint(24'hffffff); paint(24'hffffff);
        check(calibration_toggle==old_toggle,"invalid calibration preserves epoch");
        check(rg==saved_r && bg==saved_b,"clipped calibration cannot corrupt last valid gains");
        // A valid card arriving a few frames after the press is still accepted.
        paint(24'h5078a0);paint(24'h5078a0);
        check(calibration_toggle!=old_toggle,"manual window retries after initial clipped frames");
        old_toggle=calibration_toggle;saved_r=rg;saved_b=bg;
        cal_press;for(i=0;i<33;i=i+1)paint(24'hffffff);
        paint(24'h5078a0);paint(24'h5078a0);
        check(calibration_toggle==old_toggle && rg==saved_r && bg==saved_b,
              "expired invalid calibration cannot change gains later");
        $display("PASS WB neutral selection, frame-stable gains, white ROI calibration, hold/recalibrate, invalid reference");
        $finish;
    end
    initial begin #2000000; $fatal(1,"watchdog"); end
endmodule
