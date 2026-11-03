`timescale 1ns/1ps
module tb_bottle_manual;
 reg clk=0,rst=0,fs=0,de=0,learn=0,request=0,cancel=0,nav=0;
 reg [11:0] x=0,y=0;reg [23:0] rgb=0;reg [31:0] fid=0;reg [2:0] slot=0;
 wire [2:0] id,status,reason;wire [6:0] score;wire busy,done,recording,error,pulse;
 wire [7:0] saved;wire [4:0] enabled;integer xx,yy,n,v,k,level,before_saved,pulses=0;
 reg [31:0] hash0,hash1,bghash;
 reg [4:0] oldbanks;
 function [31:0] structure_hash;input integer bankbase;integer a,b;reg [31:0] h;begin h=0;for(b=0;b<3;b=b+1)for(a=0;a<1012;a=a+1)h=(h*33)^dut.LABEL.u_label.templates[(bankbase+b)*1024+a];structure_hash=h;end endfunction
 function [31:0] background_hash;input integer unused;integer a;reg [31:0] h;begin h=0;for(a=0;a<128;a=a+1)h=(h*33)^dut.background[(dut.background_bank ? 128:0)+a];background_hash=h;end endfunction
 always #5 clk=~clk;
 always @(posedge clk)if(pulse)pulses=pulses+1;
 contest_bottle_classifier #(.ROI_X(32),.ROI_Y(0),.LABEL_ENABLE(1),.MANUAL_IDENTIFY(1),.CLOCK_HZ(10000000)) dut(
 .clk(clk),.rst_n(rst),.frame_start(fs),.de(de),.x(x),.y(y),.rgb(rgb),.capture_id(fid),
 .capture_valid(1'b1),.calibration_ok(1'b1),.calibration_changed(1'b0),.learn_request(learn),
 .learn_slot(slot),.learn_cancel(cancel),.edge_strength(8'd0),.product_id(id),.status(status),
 .match_score(score),.record_counter(saved),.enabled_classes(enabled),.recording(recording),.learn_error(error),
 .identify_request(request),.identify_cancel(nav),.identify_busy(busy),.identify_done(done),.identify_reason(reason),
 .confirm_pulse(pulse));
 task tick;begin @(posedge clk);#1;end endtask
 task paint;input integer scene;
 begin
  fid=fid+1;
  for(yy=0;yy<512;yy=yy+1)for(xx=0;xx<320;xx=xx+1)begin
   @(negedge clk);de=1;x=xx;y=yy;level=128;
   if(scene!=0 && xx>=64 && xx<256 && yy>=64 && yy<448)
    level=(scene==1 ? ((xx-64)/16)%2:((yy-64)/16)%2)==0 ? 40:180;
   rgb={level[7:0],level[7:0],level[7:0]};tick;
  end
  @(negedge clk);de=0;fs=1;tick;@(negedge clk);fs=0;
  repeat(750000)tick;
 end endtask
 task enroll;input integer which,scene;
 begin
  before_saved=saved;@(negedge clk);slot=which;learn=1;tick;@(negedge clk);learn=0;
  n=0;while(saved==before_saved && n<20)begin paint(scene);n=n+1;end
  if(saved!=before_saved+1 || error)$fatal(1,"enroll failed slot%0d reason%0d state%0d",which,dut.learn_reason,dut.state);
 end endtask
 task identify;
 begin @(negedge clk);request=1;tick;@(negedge clk);request=0;end endtask
 initial begin
  repeat(5)tick;@(negedge clk);rst=1;
  enroll(5,0);
  for(k=0;k<2;k=k+1)for(v=0;v<3;v=v+1)enroll(k,k+1);
  if(enabled!=3)$fatal(1,"library incomplete");
  oldbanks=dut.active_banks;hash0=structure_hash(3);hash1=structure_hash(9);bghash=background_hash(0);
  enroll(0,2);@(negedge clk);cancel=1;tick;@(negedge clk);cancel=0;tick;
  if(dut.active_banks!=oldbanks || structure_hash(3)!==hash0 || structure_hash(9)!==hash1 || background_hash(0)!==bghash)
   $fatal(1,"cancel altered committed structure or background");
  paint(1);paint(1);if(id!=0)$fatal(1,"identified without KEY3");
  // Exercise timer rollover using real learned pixels, without forcing IDs.
  @(negedge clk);dut.time_ms=16'hfffd;
  identify;n=0;while(busy && n<18)begin paint(1);$display("manual frame %0d best%0d second%0d class%0d label%h colors%h q%0d stable%0d votes%0d max%0d",n,dut.best,dut.second,dut.best_class,dut.label_distances,dut.view_distances,dut.label_quality,dut.identify_stable,dut.identify_frames,dut.identify_max);n=n+1;end
  if(id!=1 || status!=3 || pulses!=1)$fatal(1,"manual recognition failed id%0d s%0d reason%0d",id,status,reason);
  paint(2);paint(2);if(id!=1 || pulses!=1)$fatal(1,"unsolicited class switch");
  identify;n=0;while(busy && n<18)begin paint(2);n=n+1;end
  if(id!=2 || pulses!=2)$fatal(1,"manual replacement failed id%0d reason%0d",id,reason);
  identify;n=0;while(busy && n<18)begin paint(2);n=n+1;end
  if(id!=2 || pulses!=2)$fatal(1,"same episode beep repeated");
  paint(0);paint(0);if(id!=0 || status!=1)$fatal(1,"empty regression");
  identify;nav=1;tick;nav=0;tick;if(busy)$fatal(1,"navigation failed to cancel");
  identify;repeat(20010000)tick;
  if(busy || reason!=4)$fatal(1,"missing-frame timeout failed");
  $display("PASS integrated manual key request, actual label enrollment, same-color classes, no unsolicited switching, beep deduplication, empty and timeout");$finish;
 end
 initial begin #(64'd5000000000);$fatal(1,"manual watchdog");end
endmodule
