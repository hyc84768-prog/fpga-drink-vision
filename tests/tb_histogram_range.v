`timescale 1ns/1ps
module tb_histogram_range;
    reg clk=0,rst_n=0,fs=0,de=0;
    reg [11:0] x=0,y=0;
    reg [7:0] luma=0;
    wire [7:0] eq;
    wire ready;
    integer xx,yy,i,cdf,first_count,mapped,expected;
    always #5 clk=~clk;
    contest_histogram_equalizer #(.WIDTH(128),.HEIGHT(128)) dut(clk,rst_n,fs,de,x,y,luma,eq,ready);
    task tick;begin @(posedge clk);#1;end endtask
    task start;begin @(negedge clk);fs=1;de=0;tick;@(negedge clk);fs=0;end endtask
    initial begin
        repeat(5)tick;@(negedge clk);rst_n=1;repeat(270)tick;start;
        for(yy=0;yy<128;yy=yy+1)begin
            for(xx=0;xx<128;xx=xx+1)begin
                @(negedge clk);de=1;x=xx;y=yy;luma=xx<64 ? 30:180;tick;
            end
            @(negedge clk);de=0;repeat(4)tick;
        end
        repeat(8)tick;start;repeat(10000)tick;
        if(dut.cdf!=1024 || dut.excess!=1008)$fatal(1,"CLHE sample/excess conservation %0d/%0d",dut.cdf,dut.excess);
        start;repeat(6)tick;
        cdf=0;first_count=4;
        for(i=0;i<256;i=i+1)begin
            cdf=cdf+3+(i<240 ? 1:0)+(i==30 || i==180 ? 8:0);
            mapped=((cdf-first_count)*255)/(1024-first_count);
            expected=(i+mapped+1)/2;
            @(negedge clk);de=0;luma=i;repeat(4)tick;
            if(!ready || eq!==expected[7:0])$fatal(1,"24-bit CDF numerator or blending mismatch at %0d: %0d/%0d",i,eq,expected);
        end
        if(cdf!=1024)$fatal(1,"reference sample conservation");
        $display("PASS CLHE 1024-sample accumulation, excess distribution conservation, 24-bit CDF numerator and all 256 blended LUT values");$finish;
    end
endmodule
