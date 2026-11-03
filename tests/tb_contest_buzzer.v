`timescale 1ns/1ps
module tb_contest_buzzer;
    reg clk=0,rst_n=0,alert=0;
    wire buzzer_n,active_n;
    integer i,run_length,transitions;
    reg previous;
    always #5 clk=~clk;
    // Default 50 MHz clock / 2 kHz tone = 12500 clocks per half period.
    contest_buzzer_driver dut(clk,rst_n,alert,buzzer_n);
    contest_buzzer_driver #(.TONE_HZ(0)) dc(clk,rst_n,alert,active_n);
    task tick; begin @(posedge clk); #1; end endtask
    initial begin
        repeat(3) tick;
        @(negedge clk); rst_n=1; repeat(5) tick;
        if(buzzer_n!==1 || active_n!==1) $fatal(1,"buzzer must idle high");
        @(negedge clk); alert=1;
        repeat(2) tick;
        previous=buzzer_n; run_length=0; transitions=0;
        for(i=0;i<100000;i=i+1) begin
            tick; run_length=run_length+1;
            if(buzzer_n!==previous) begin
                if(run_length!=12500) $fatal(1,"wrong half-period %0d",run_length);
                previous=buzzer_n; run_length=0; transitions=transitions+1;
            end
            if(active_n!==0) $fatal(1,"active buzzer compatibility mode");
        end
        if(transitions!=8) $fatal(1,"tone transition count");
        @(negedge clk); alert=0; repeat(3) tick;
        if(buzzer_n!==1 || active_n!==1) $fatal(1,"buzzer must stop on alert removal");
        @(negedge clk); alert=1; repeat(13000) tick;
        @(negedge clk); rst_n=0; #1;
        if(buzzer_n!==1 || active_n!==1) $fatal(1,"reset must silence buzzer");
        $display("PASS buzzer 2kHz 50-percent duty, CDC enable, idle/reset, active-mode fallback");
        $finish;
    end
    initial begin #2000000; $fatal(1,"watchdog"); end
endmodule
