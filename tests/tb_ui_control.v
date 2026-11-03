`timescale 1ns/1ps
module tb_ui_control;
    reg clk=0,rst_n=0,fs=0,recording=0,library_present=0,calibration_changed=0;
    reg [3:0] key_n=4'hf,switches=12;
    wire [1:0] group_id;
    wire [2:0] page,menu_item,selected_class,effect_mode,learn_slot;
    wire [3:0] filtered;
    wire identify_request;
    integer identifications=0;
    wire learn_request,learn_cancel,calibration_request,group_changed,write_blocked,cal_timeout;
    integer requests=0,cancels=0,calibrations=0,changes=0,i,j,before_requests,before_cancels;
    reg [5:0] seen_slots=0;
    always #5 clk=~clk;
    contest_ui_control #(.DEBOUNCE(3),.CLOCK_HZ(100000),.CAL_TIMEOUT_MS(8)) dut(
        .clk(clk),.rst_n(rst_n),.frame_start(fs),.key_n(key_n),.switches(switches),
        .recording(recording),.library_present(library_present),.calibration_changed(calibration_changed),
        .group_id(group_id),.page(page),.menu_item(menu_item),.selected_class(selected_class),.effect_mode(effect_mode),
        .switches_filtered(filtered),.learn_slot(learn_slot),.learn_request(learn_request),.learn_cancel(learn_cancel),
        .calibration_request(calibration_request),.group_changed(group_changed),
        .identify_request(identify_request),.write_blocked(write_blocked),.cal_timeout(cal_timeout));
    always @(posedge clk) if(rst_n) begin
        if(identify_request)identifications=identifications+1;
        if(learn_request) begin requests=requests+1;seen_slots[learn_slot]=1;end
        if(learn_cancel)cancels=cancels+1;
        if(calibration_request)calibrations=calibrations+1;
        if(group_changed)changes=changes+1;
    end
    task tick;begin @(posedge clk);#1;end endtask
    task check;input good;input [511:0] msg;
        begin if(good!==1'b1)begin $display("FAIL %0s",msg);$fatal(1);end end
    endtask
    task frame;begin @(negedge clk);fs=1;tick;@(negedge clk);fs=0;repeat(3)tick;end endtask
    task post;input integer key;
        begin @(negedge clk);key_n[key]=0;repeat(8)tick;
            @(negedge clk);key_n[key]=1;repeat(8)tick;end
    endtask
    task press;input integer key;begin post(key);frame;end endtask
    task reset;begin @(negedge clk);rst_n=0;key_n=15;switches=12;recording=0;calibration_changed=0;
        repeat(4)tick;@(negedge clk);rst_n=1;repeat(8)tick;end endtask
    task menu;input integer item;
        begin
            if(page==0)press(1);
            while(menu_item!=item)press(1);
            press(2);
        end
    endtask
    initial begin
        reset;
        check(group_id==0 && page==0 && filtered==12,"startup drink/live/enable switches");
        press(2);check(identifications==1 && requests==0,"live KEY3 posts one recognition, not a learning request");
        frame;frame;check(identifications==1,"recognition request is consumed once");
        // Short glitches do not qualify. Held keys neither act nor repeat.
        @(negedge clk);key_n[0]=0;tick;@(negedge clk);key_n[0]=1;repeat(8)tick;frame;
        check(group_id==0,"contact bounce ignored");
        @(negedge clk);key_n[0]=0;repeat(20)tick;frame;frame;
        check(group_id==0,"held key waits for release");
        @(negedge clk);key_n[0]=1;repeat(8)tick;
        check(group_id==0,"release queued before VS");
        frame;check(group_id==1,"K1 release commits on VS");
        frame;check(group_id==1,"queued action is consumed once");
        press(1);press(2);press(3);
        check(group_id==1 && page==0 && requests==0 && identifications==1,"red group ignores drink actions");
        press(0);check(group_id==2,"algorithm group");
        for(i=1;i<=7;i=i+1)begin press(1);check(effect_mode==i%7,"seven algorithms wrap");end
        check(dut.effect_level==1,"default normal effect strength");
        press(2);check(requests==0 && dut.effect_level==2,"algorithm KEY3 changes strength without learning");
        press(2);check(dut.effect_level==0,"strength wraps to detail");
        press(2);check(dut.effect_level==1,"strength wraps to normal");
        press(0);check(group_id==0 && page==0,"group wrap");

        // All five class slots are directly accessible, each short K3 samples.
        menu(1);check(page==2,"library entry");
        for(i=0;i<5;i=i+1)begin
            check(selected_class==i,"selected class order");
            press(2);check(page==3 && learn_slot==i,"record entry does not sample");
            before_requests=requests;press(2);
            check(requests==before_requests+1,"short K3 records exactly once");
            before_requests=requests;recording=1;press(2);recording=0;frame;
            check(requests==before_requests,"busy K3 is discarded rather than deferred");
            before_cancels=cancels;press(3);
            check(page==2 && cancels==before_cancels+1,"back cancels staged set");
            press(1);
        end
        check(selected_class==0 && seen_slots[4:0]==31,"five-slot selection wraps");
        press(3);menu(2);check(page==4 && learn_slot==5,"background entry");
        press(2);check(seen_slots==63,"background uses slot5");
        before_cancels=cancels;press(0);
        check(group_id==1 && page==0 && cancels==before_cancels+1,"group change cancels background staging");
        press(0);press(0);

        // Filter switches independently, then enforce write protection at action.
        switches=4'b0111;repeat(8)tick;check(filtered==7,"switches filtered, SW4=0 protects");
        menu(1);press(2);before_requests=requests;press(2);
        check(write_blocked && requests==before_requests,"protected sample blocked");
        press(3);press(3);menu(2);press(2);
        check(write_blocked && requests==before_requests,"protected background blocked");
        press(3);menu(3);press(2);
        check(write_blocked && calibrations==0 && page==5,"protected maintenance blocked");
        switches=12;repeat(8)tick;check(filtered==12,"switch enable filtered");
        frame;check(!write_blocked,"SW4=1 clears blocked notice without another key");
        // Even an empty library requires a separate maintenance confirmation.
        check(calibrations==0,"maintenance entry is not calibration itself");
        press(2);check(calibrations==1 && page==7,"explicit confirmation launches calibration");
        post(0);post(3);frame;check(group_id==0 && page==7,"in-flight calibration cannot be navigated away");
        @(negedge clk);calibration_changed=1;tick;@(negedge clk);calibration_changed=0;
        repeat(4)tick;check(page==7,"successful calibration waits for VS");
        frame;check(page==0 && !cal_timeout,"latched successful calibration returns live");
        menu(3);press(2);check(page==7 && calibrations==2,"repeat maintenance");
        repeat(850)tick;check(page==7,"wall-clock timeout waits for frame commit");
        frame;check(page==5 && cal_timeout,"maintenance timeout permits retry");
        press(3);check(page==1 && !cal_timeout,"back clears notice");
        menu(4);check(page==6,"diagnostic entry");press(3);check(page==1,"diagnostic back");
        press(3);check(page==0,"menu back returns live");

        // Concurrent releases take K1 over K4 over K2 over K3.
        @(negedge clk);key_n=0;repeat(8)tick;@(negedge clk);key_n=15;repeat(8)tick;frame;
        check(group_id==1 && page==0,"simultaneous K1 priority");
        press(0);press(0);menu(1);press(2);before_requests=requests;before_cancels=cancels;
        @(negedge clk);key_n[2]=0;key_n[3]=0;repeat(8)tick;
        @(negedge clk);key_n=15;repeat(8)tick;frame;
        check(page==2 && requests==before_requests && cancels==before_cancels+1,"K4 cancels before K3 can sample");
        $display("PASS  four-key debounce/release/VS queue, three groups, six algorithms, five class slots/background, busy/write protection, cancel, maintenance success/timeout and event priority");
        $finish;
    end
    initial begin #2000000;$fatal(1,"watchdog");end
endmodule
