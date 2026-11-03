`timescale 1ns/1ps
module w128_d512_fifo(input rst,clkw,we,input [127:0] di,
    output afull,full_flag,output [8:0] wrusedw,input clkr,re,
    output [127:0] dout,output [8:0] rdusedw,output valid,empty_flag,aempty);
    assign afull=0,full_flag=0,wrusedw=0,dout=0,rdusedw=0;
    assign valid=0,empty_flag=1,aempty=1;
endmodule
module tb_video_age;
    reg camera_clk=0, ddr_clk=0, rst_n=0, camera_frame_start=0;
    reg display_frame_start=0, mipi_error=0, pause=0;
    wire [1:0] read_slot;
    wire [7:0] age_gray;
    wire age_valid;
    wire [31:0] capture_id;
    wire busy,wr_en;
    wire [24:0] addr;
    wire [127:0] data;
    integer i;
    reg [7:0] decoded;
    always #7 camera_clk=~camera_clk;
    always #5 ddr_clk=~ddr_clk;
    video_in dut(rst_n,camera_clk,camera_frame_start,1'b0,128'd0,
        mipi_error,ddr_clk,pause,1'b0,display_frame_start,busy,
        read_slot,age_gray,age_valid,capture_id,wr_en,addr,data,1'b0);
    task capture;
        begin
            @(negedge camera_clk); camera_frame_start=1;
            @(negedge camera_clk);
            camera_frame_start=0;
            repeat(24) @(negedge camera_clk);
        end
    endtask
    task display;
        begin
            @(negedge ddr_clk); display_frame_start=1;
            @(negedge ddr_clk); display_frame_start=0;
            decoded=age_gray;
            for(i=1;i<8;i=i<<1) decoded=decoded^(decoded>>i);
        end
    endtask
    initial begin
        repeat(4) @(negedge ddr_clk); rst_n=1;
        capture(); display();
        if(age_valid) $fatal(1,"invalid startup slot marked valid");
        capture(); capture(); display();
        if(read_slot!=0 || !age_valid || decoded!=2 || capture_id!=1)
            $fatal(1,"frame slot/age wrong: %0d %0d %0d",read_slot,age_valid,decoded);
        mipi_error=1; capture(); display();
        if(decoded!=2 || capture_id!=1) $fatal(1,"errored capture advanced frame age/ID");
        $display("PASS DDR frame slot, 32-bit capture ID and estimated frame age");
        $finish;
    end
endmodule
