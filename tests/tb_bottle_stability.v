`timescale 1ns/1ps
// Whole RGB frames, real three-view learning and independent illumination/
// replacement sequences. No forced DUT distances or canned classification IDs.
module tb_bottle_stability;
 reg clk=0,rst_n=0,fs=0,de=0,learn=0,cancel=0;
 reg [11:0] x=0,y=0;reg [23:0] rgb=0;
 reg [31:0] capture_id=0;
 reg [2:0] slot=0;reg [7:0] edge_strength=0;
 wire [2:0] id,status;wire [6:0] score;wire [4:0] enabled;
 wire recording,error,pulse;wire [7:0] saved;wire [15:0] bg,best,inc;
 integer xx,yy,c,v,n,before_saved,weak_points=375,color_index,body_left;
 integer confirmations=0,before_pulses;
 reg [7:0] rr,gg,bb;reg body,label;
 always #5 clk=~clk;
 always @(posedge clk)if(rst_n && pulse)confirmations=confirmations+1;
 contest_bottle_classifier #(.ROI_X(32),.ROI_Y(0),.CLOCK_HZ(1000000),
   .CONFIRM_MS(30),.SWITCH_MS(160),.LOSS_MS(60),.LEARN_TIMEOUT_MS(500)) dut(
   .clk(clk),.rst_n(rst_n),.frame_start(fs),.de(de),.x(x),.y(y),.rgb(rgb),
   .capture_id(capture_id),.capture_valid(1'b1),.calibration_ok(1'b1),
   .learn_request(learn),.learn_slot(slot),.product_id(id),.status(status),.match_score(score),
   .enabled_classes(enabled),.learn_error(error),.record_counter(saved),.recording(recording),
   .learn_cancel(cancel),.calibration_changed(1'b0),.edge_strength(edge_strength),.confirm_pulse(pulse),
   .debug_background(bg),.debug_best(best),.debug_incumbent(inc));
 task tick;begin @(posedge clk);#1;end endtask
 task boundary;begin @(negedge clk);de=0;fs=1;tick;@(negedge clk);fs=0;end endtask
 task paint;input integer scene,percent,view;
  begin
   capture_id=capture_id+1;color_index=0;body_left=96+(view==1 ? -8:view==2 ? 8:0);
   for(yy=0;yy<512;yy=yy+8)for(xx=0;xx<320;xx=xx+8)begin
    @(negedge clk);x=xx;y=yy;de=1;rr=128;gg=128;bb=128;edge_strength=0;
    body=xx>=body_left && xx<body_left+128 && yy>=64 && yy<448 && scene!=0;
    label=body && (yy>=192 && yy<256 || yy>=288 && yy<320);
    if(body)begin
     case(scene)
      1:begin rr=180;gg=145;bb=90;end
      2,7:begin rr=210;gg=30;bb=30;end
      3:begin rr=30;gg=180;bb=40;end
      4:begin rr=35;gg=60;bb=210;end
      5:begin rr=24;gg=24;bb=24;end
      default:begin rr=190;gg=40;bb=180;end
     endcase
     if(label)begin rr=yy<256 ? 32:210;gg=rr;bb=rr;end
     else begin
      if(scene==7 && color_index<weak_points)begin rr=190;gg=40;bb=180;end
      color_index=color_index+1;
     end
     if(xx==body_left || xx==body_left+120 || yy==64 || yy==192 || yy==288 || yy==440)edge_strength=32;
    end
    // A deliberately low-contrast class: color distance below the broad
    // acceptance limit, no edge evidence, yet distinguishable from background.
    if(scene==6)begin
     rr=128;gg=128;bb=128;edge_strength=0;
     if(xx>=32 && xx<288 && yy<16)begin rr=210;gg=30;bb=30;end
    end
    rr=(rr*percent)/100;gg=(gg*percent)/100;bb=(bb*percent)/100;
    rgb={rr,gg,bb};tick;
   end
   @(negedge clk);de=0;repeat(3)tick;boundary;repeat(7000)tick;
  end
 endtask
 task record_view;input integer which,scene,view;
  begin
   before_saved=saved;@(negedge clk);slot=which;learn=1;tick;@(negedge clk);learn=0;
   n=0;while(saved==before_saved && n<20)begin paint(scene,100,view);n=n+1;end
   if(saved!=before_saved+1 || error || recording)$fatal(1,"learning %0d/%0d failed",which,view);
  end
 endtask
 task acquire;input integer scene,want,view;
  begin
   n=0;while((id!=want || status!=3) && n<28)begin paint(scene,100,view);n=n+1;end
   if(id!=want || status!=3)$fatal(1,"did not acquire scene%0d ID%0d (ID%0d best%0d bg%0d)",scene,want,id,best,bg);
  end
 endtask
 initial begin
  repeat(5)tick;@(negedge clk);rst_n=1;boundary;
  record_view(5,0,0);
  for(c=0;c<5;c=c+1)for(v=0;v<3;v=v+1)record_view(c,c+1,v);
  if(enabled!=31)$fatal(1,"five classes not committed");
  for(c=0;c<5;c=c+1)begin
   for(v=0;v<3;v=v+1)acquire(c+1,c+1,v);
   before_pulses=confirmations;
   for(n=0;n<18;n=n+1)begin
    paint(c+1,n%3==0 ? 70:n%3==1 ? 100:120,0);
    if(id!=c+1 || status!=3)$fatal(1,"stationary ID changed under illumination class%0d id%0d",c+1,id);
   end
   if(confirmations!=before_pulses)$fatal(1,"illumination retriggered confirmation");
   paint(0,100,0);paint(0,100,0);
   if(id!=0 || status!=1)$fatal(1,"removal did not clear color class%0d",c+1);
  end
  acquire(1,1,0);
  // Reproduce the old UNKNOWN loophole: rival fits initial threshold but
  // fails the strict switch threshold. It must not become a new initial ID.
  for(n=0;n<12;n=n+1)paint(8,100,0);
  if(id!=0 || status!=2 || dut.confirmed_class!=1)$fatal(1,"uncertainty erased the confirmed episode");
  before_pulses=confirmations;
  for(n=0;n<28;n=n+1)paint(7,100,0);
  if(!dut.initial_good || dut.switch_good || best<=1350 || best>1650)
   $fatal(1,"weak-rival fixture not between thresholds: %0d",best);
  if(id==2 || dut.confirmed_class!=1 || confirmations!=before_pulses)$fatal(1,"UNKNOWN bypassed switch gate");
  acquire(2,2,0);
  // Subtle one-frame contamination uses filtered features; large scene changes
  // bypass the IIR so previous products cannot bleed into a replacement.
  for(n=0;n<4;n=n+1)paint(2,100,0);
  weak_points=12;paint(7,100,0);
  if(!dut.use_filtered || inc>=48 || id!=2)$fatal(1,"temporal feature filter did not attenuate small noise %0d",inc);
  // A very close background must clear even when the old class remains a
  // high-scoring match, rather than keeping KNOWN forever.
  for(v=0;v<3;v=v+1)record_view(4,6,0);
  acquire(6,5,0);
  paint(0,100,0);paint(0,100,0);
  if(id!=0 || status!=1 || best>1650)$fatal(1,"high-scoring old class defeated independent EMPTY");
  $display("PASS  real RGB/rail frames: five 3-view classes, stationary 0.7x-1.2x illumination, no repeated beep, removal with high match score, UNKNOWN strict-switch memory, noise IIR and replacement reset");$finish;
 end
 initial begin #300000000;$fatal(1,"stability watchdog");end
endmodule
