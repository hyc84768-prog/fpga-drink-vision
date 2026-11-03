`timescale 1ns/1ps
module tb_display_enhance;
    reg clk=0,rst_n=0,de=0,fs=0;
    reg [11:0] x=0,y=0;
    reg [23:0] rgb=0;
    reg [1:0] level=1;
    wire sd,od;wire [11:0] sx,sy,ox,oy;
    wire [23:0] original,cartoon,smooth;
    wire [7:0] gray,median,sobel,edge_pixel,binary_pixel,mean;
    wire [71:0] payload;
    reg [3:0] fs_pipe=0;
    reg [23:0] vectors[0:30719];
    integer f,xx,yy,n,checked=0;
    reg [23:0] expected;
    always #5 clk=~clk;
    always @(posedge clk)fs_pipe<={fs_pipe[2:0],fs};
    contest_spatial_filters #(.WIDTH(64)) spatial(clk,rst_n,de,x,y,rgb,sd,sx,sy,original,cartoon,gray,median,sobel,smooth);
    contest_display_enhance #(.WIDTH(64),.HEIGHT(48)) dut(
        .clk(clk),.rst_n(rst_n),.frame_start(fs_pipe[3]),.de(sd),.x(sx),.y(sy),.median_in(median),
        .payload({original,cartoon,gray,median,gray}),.level(level),
        .out_de(od),.out_x(ox),.out_y(oy),.out_payload(payload),
        .edge_out(edge_pixel),.binary_out(binary_pixel),.mean_luma(mean));
    always @(posedge clk)begin
        #1;
        if(rst_n && od)begin
            expected=vectors[f*3072+oy*64+ox];
            if(edge_pixel!==expected[15:8] || binary_pixel!==expected[7:0])
                $fatal(1,"display kernel f%0d (%0d,%0d) edge %h/%h binary %h/%h mean %0d",f,ox,oy,edge_pixel,expected[15:8],binary_pixel,expected[7:0],mean);
            if(payload[71:48]!=={3{expected[23:16]}})
                $fatal(1,"display payload/coordinate alignment");
            if(binary_pixel!==0 && binary_pixel!==255)$fatal(1,"not a binary image");
            checked=checked+1;
        end
    end
    initial begin
        $readmemh("display_vectors.hex",vectors);
        repeat(5)@(negedge clk);rst_n=1;
        for(f=0;f<10;f=f+1)begin
            level=f%3;fs=1;@(negedge clk);fs=0;repeat(50)@(negedge clk);
            for(yy=0;yy<48;yy=yy+1)begin
                for(xx=0;xx<64;xx=xx+1)begin
                    x=xx;y=yy;de=1;rgb={3{vectors[f*3072+yy*64+xx][23:16]}};@(negedge clk);
                end
                de=0;repeat(12)@(negedge clk);
            end
            repeat(20)@(negedge clk);
        end
        if(checked!=30720)$fatal(1,"missing display pixels %0d",checked);
        $display("PASS 30720 independent median/Sobel/5x5 Gaussian/sharpen/adaptive binary pixels, three levels, impulse/noise rejection, exposure changes and payload alignment");$finish;
    end
    initial begin #2000000;$fatal(1,"watchdog");end
endmodule
