`timescale 1ns/1ps
module tb_frame_mailbox;
    reg sc=0,dc=0,rst_n=0,submit=0,sv=0;
    reg [31:0] sid=0;
    wire [31:0] did;
    wire dv;
    always #7 sc=~sc;
    always #5 dc=~dc;
    contest_frame_mailbox dut(sc,dc,rst_n,submit,sid,sv,did,dv);
    task send;input [31:0] value;input good;
        begin
            @(negedge sc);sid=value;sv=good;submit=1;
            @(negedge sc);submit=0;
            repeat(2)@(negedge sc);sid=~value;sv=!good;
            repeat(20)@(negedge dc);
            if(did!==value || dv!==good)$fatal(1,"torn mailbox payload %h expected %h",did,value);
        end
    endtask
    initial begin
        repeat(4)@(negedge sc);rst_n=1;
        send(32'h0000ffff,1);send(32'hffff0000,1);send(32'h11112222,0);send(32'h00000000,1);
        @(negedge sc);rst_n=0;repeat(5)@(negedge dc);
        if(dv || did!=0)$fatal(1,"reset metadata invalidation");
        $display("PASS asynchronous frame metadata mailbox, held payload, skipped IDs, validity and reset");$finish;
    end
endmodule
