`timescale 1ns/1ps
// Behavioral latency model isolates the AWB wrapper from vendor RAM/IP.
// The real, existing signal_delay/RAM topology is retained in the TD build.
module signal_delay #(parameter IMG_HEIGHT=64,IMG_WIDTH=128,DATA_WIDTH=96,DELAY_CYCLE=50)(
    input I_clk,I_rst_n,I_tuser,I_valid,input [DATA_WIDTH-1:0] I_data,
    output O_valid,output [DATA_WIDTH-1:0] O_data,output O_tuser);
    reg [DELAY_CYCLE-1:0] v;
    reg [DATA_WIDTH-1:0] d[0:DELAY_CYCLE-1];
    integer i;
    always @(posedge I_clk) begin
        if(!I_rst_n) begin v<=0; for(i=0;i<DELAY_CYCLE;i=i+1) d[i]<=0; end
        else begin
            v<={v[DELAY_CYCLE-2:0],I_valid}; d[0]<=I_data;
            for(i=1;i<DELAY_CYCLE;i=i+1) d[i]<=d[i-1];
        end
    end
    assign O_valid=v[DELAY_CYCLE-1],O_data=d[DELAY_CYCLE-1],O_tuser=0;
endmodule
module tb_awb_stream;
    reg clk=0,rst_n=0,valid=0,user=0;
    reg [95:0] data=0;
    wire ready,ov,ol,ou,updated,locked;
    wire [95:0] od;
    reg [53:0] ref_valid=0;
    reg [95:0] ref_data[0:53];
    integer i,j,k,checked=0;
    always #5 clk=~clk;
    awb #(.IMG_WIDTH(128),.IMG_HEIGHT(64)) dut(
        .I_clk(clk),.I_rst_n(rst_n),.I_tlast(1'b0),.I_tuser(user),.I_tdata(data),.I_tvalid(valid),
        .I_tready(ready),.O_tlast(ol),.O_tuser(ou),.O_tdata(od),.O_tvalid(ov),
        .O_gain_updated(updated),.O_locked(locked),.I_cal_key_n(1'b1),.I_cal_request_toggle(1'b0),.O_tready(1'b1));
    always @(posedge clk) if(rst_n) begin
        ref_valid={ref_valid[52:0],valid};
        for(i=53;i>0;i=i-1) ref_data[i]=ref_data[i-1];
        ref_data[0]=data;
        #1;
        if(ov!==ref_valid[53]) $fatal(1,"AWB stream latency mismatch");
        if(ov) begin
            if(od!==ref_data[53]) $fatal(1,"AWB RGB lane order or gain mismatch");
            checked=checked+1;
        end
        if(ol!==(ref_valid[53] && !ref_valid[52])) $fatal(1,"AWB line-last alignment");
    end
    task tick; begin @(posedge clk); #2; end endtask
    initial begin
        for(i=0;i<54;i=i+1) ref_data[i]=0;
        repeat(4) tick; @(negedge clk); rst_n=1; user=1; #1;
        if(ou!==1) $fatal(1,"AWB frame-start must lead delayed pixels for DDR reset");
        tick; @(negedge clk); user=0; repeat(10) tick;
        for(j=0;j<4;j=j+1) begin
            for(k=0;k<32;k=k+1) begin
                @(negedge clk); valid=1; data={24'hc01010,24'hb01010,24'ha01010,24'h901010}; tick;
            end
            @(negedge clk); valid=0; repeat(8) tick;
        end
        repeat(100) tick;
        if(checked!=128 || updated || locked) $fatal(1,"AWB valid count or saturated scene statistics");
        $display("PASS AWB stream latency, RGB lane order, early DDR frame marker (behavioral delay model)");
        $finish;
    end
endmodule
