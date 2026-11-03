`timescale 1ns/1ps
module tb_bayer_color;
    reg clk=0,rst_n=0,valid=0,yp=0;
    reg [95:0] prev=0,cur=0,next=0;
    wire [127:0] data;
    wire ov,last,user,ready;
    integer i,j;
    always #5 clk=~clk;
    bilinear_interpolation #(.BAYER_MODE("BGGR")) dut(
        .I_clk(clk),.I_rst_n(rst_n),.I_tlast(1'b0),.I_tuser(1'b0),.I_tvalid(valid),.I_tready(ready),
        .bayer_ypos(yp),.matrix_last_line(prev),.matrix_cur_line(cur),.matrix_next_line(next),
        .O_tlast(last),.O_tuser(user),.O_tdata(data),.O_tvalid(ov),.O_tready(1'b1));
    task tick; begin @(posedge clk); #1; end endtask
    task tile; input parity; input [7:0] r,g,b;
        begin
            @(negedge clk); yp=parity; valid=1;
            if(parity) begin
                prev={24'd0,g,b,g,b,g,b,24'd0}; cur={24'd0,r,g,r,g,r,g,24'd0}; next=prev;
            end else begin
                prev={24'd0,r,g,r,g,r,g,24'd0}; cur={24'd0,g,b,g,b,g,b,24'd0}; next=prev;
            end
            repeat(12) tick;
            if(!ov) $fatal(1,"Bayer pipeline not valid");
            for(j=0;j<4;j=j+1)
                if(data[j*32+:32]!=={8'd0,r,g,b})
                    $fatal(1,"BGGR parity %0d lane %0d: %h expected %h",parity,j,data[j*32+:32],{8'd0,r,g,b});
        end
    endtask
    initial begin
        repeat(3) tick; @(negedge clk); rst_n=1;
        tile(0,200,80,40); tile(1,200,80,40);
        tile(0,40,80,200); tile(1,40,80,200);
        tile(0,128,128,128); tile(1,128,128,128);
        $display("PASS BGGR synthetic red/blue/neutral tiles, both row parities, all four RGB lanes");
        $finish;
    end
endmodule
