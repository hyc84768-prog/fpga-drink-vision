`timescale 1ns/1ps
module tb_contest_auto_exposure;
    reg camera_clk=0,cfg_clk=0,rst_n=0,frame_start=0,valid=0;
    reg camera_configured=0,write_complete=1,exposure_hold=0;
    reg mixed_lanes=0;
    reg [95:0] pixels=0;
    wire request,adjustment_seen,hold_active;
    wire [15:0] exposure,gain;
    wire [23:0] gain_registers,init_register;
    wire [8:0] init_size;
    reg [8:0] init_index=104;
    SC520GainTbl table_gain(gain,gain_registers);
    uics520reg_720p60 table_init(init_index,init_register,init_size);
    integer requests=0,row,col,n;
    reg [15:0] previous_exposure;
    always #3 camera_clk=~camera_clk;
    always #5 cfg_clk=~cfg_clk;
    contest_auto_exposure #(.WIDTH(128),.HEIGHT(64),.MIN_SAMPLES(8)) dut(
        camera_clk,cfg_clk,rst_n,frame_start,valid,pixels,camera_configured,
        write_complete,request,exposure,gain,adjustment_seen,exposure_hold,hold_active);
    always @(posedge cfg_clk)if(request)requests=requests+1;
    task boundary;begin
        @(negedge camera_clk);frame_start=1;valid=0;
        @(negedge camera_clk);frame_start=0;
        repeat(20)@(negedge cfg_clk);
    end endtask
    task paint;input [7:0] center,background;
        reg [7:0] v;
        begin
            boundary;
            for(row=0;row<64;row=row+1)begin
                for(col=0;col<128;col=col+4)begin
                    @(negedge camera_clk);valid=1;
                    v=(col>=32 && col<96 && row>=16 && row<48) ? center:background;
                    pixels={4{v,v,v}};
                    if(mixed_lanes && col>=32 && col<96 && row>=16 && row<48)
                        pixels={24'hf0f0f0,24'hf0f0f0,48'd0};
                end
                @(negedge camera_clk);valid=0;
            end
        end
    endtask
    task ack;begin
        write_complete=0;repeat(5)@(negedge cfg_clk);
        write_complete=1;repeat(8)@(negedge cfg_clk);
        repeat(8)@(negedge camera_clk);
    end endtask
    initial begin
        repeat(4)@(negedge cfg_clk);rst_n=1;camera_configured=1;
        if(exposure!=1991)$fatal(1,"AE startup differs from sensor exposure table");
        if(init_size!=167 || init_register!=24'h3e017c || gain_registers!=24'h000080)
            $fatal(1,"initial exposure/gain table mismatch");
        init_index=164;#1;if(init_register!=24'h3e0600)$fatal(1,"initial digital coarse gain");
        init_index=165;#1;if(init_register!=24'h3e0780)$fatal(1,"initial digital unity gain");
        init_index=166;#1;if(init_register!=24'h010001)$fatal(1,"stream-on is not last");
        mixed_lanes=1;paint(120,255);boundary;mixed_lanes=0;
        if(requests!=0)$fatal(1,"meter must average all four lanes and exclude bright border");
        paint(255,0);boundary;
        if(requests!=1 || exposure!=1863 || adjustment_seen)
            $fatal(1,"bright ROI/adaptive step/handshake %0d %0d",requests,exposure);
        paint(255,0);boundary;
        if(requests!=1)$fatal(1,"overlapping camera update");
        exposure_hold=1;repeat(8)@(negedge camera_clk);
        if(hold_active)$fatal(1,"hold before outstanding write ack");
        ack;if(!hold_active || !adjustment_seen)$fatal(1,"hold did not settle after camera ack");
        paint(0,255);paint(255,0);boundary;
        if(requests!=1 || exposure!=1863)$fatal(1,"HOLD changed exposure");
        exposure_hold=0;repeat(8)@(negedge camera_clk);
        if(hold_active)$fatal(1,"AUTO did not resume");
        paint(255,0);boundary;
        if(requests!=2 || exposure>=1863)$fatal(1,"AUTO resume ignored bright center");
        ack;previous_exposure=exposure;
        paint(0,255);boundary;
        if(requests!=3 || exposure<=previous_exposure)$fatal(1,"dark center must increase exposure");
        ack;
        for(n=0;n<24;n=n+1)begin paint(0,255);boundary;ack;end
        if(exposure!=1991)$fatal(1,"exposure failed to reach maximum %0d",exposure);
        if(gain!=80 || gain_registers!=24'h090080)$fatal(1,"dark gain exceeded/did not reach bounded 4x");
        previous_exposure=exposure;
        paint(255,0);boundary;ack;
        if(gain!=76 || exposure!=previous_exposure)$fatal(1,"bright scene must shed gain before exposure");
        $display("PASS  four-lane central ROI, sensor-consistent startup, adaptive bounded exposure, in-flight hold and resume");
        $finish;
    end
    initial begin #3000000;$fatal(1,"AE watchdog");end
endmodule
