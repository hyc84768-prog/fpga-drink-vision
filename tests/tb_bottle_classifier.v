`timescale 1ns/1ps
module tb_bottle_classifier;
 reg clk=0,rst_n=0,fs=0,de=0,valid=1,cal=1,learn=0,cancel=0,changed=0;
 reg [11:0] x=0,y=0;
 reg [23:0] rgb=0;
 reg [7:0] edge_strength=0;
 wire background_ready,confirm_pulse;
 integer confirmations=0,edge_level=0,edge_points=-1,white_points=0;
 always @(posedge clk) if(rst_n && confirm_pulse) confirmations=confirmations+1;
 reg [31:0] fid=0,next_id=1;
 reg [2:0] slot=0;
 wire [2:0] id,status,reason,record_slot;
 wire [6:0] score;
 wire [4:0] learned,enabled;
 wire error,recording;
 wire [31:0] result_id;
 wire [7:0] record_counter;
 wire [1:0] record_view,session;
 wire [9:0] sample_counts;
 wire [3:0] progress;
 integer xx,yy,i,c,v,n,old_counter,before_votes,start_ms;
 reg old_bank;
 reg [7:0] model_copy[0:1919],bg_copy[0:127];
 reg [4:0] mask_copy;
 integer before_confirmations,saved_counter;
 always #5 clk=~clk;
 contest_bottle_classifier #(.ROI_X(0),.ROI_Y(0),.STALE_FRAMES(12),
  .CLOCK_HZ(1000000),.CONFIRM_MS(70),.LEARN_TIMEOUT_MS(500),
  .SWITCH_MS(70),.SWITCH_FRAMES(6),.LOSS_MS(0),.TEMPORAL_FILTER(0)) dut(
  .clk(clk),.rst_n(rst_n),.frame_start(fs),.de(de),.x(x),.y(y),.rgb(rgb),
  .capture_id(fid),.capture_valid(valid),.calibration_ok(cal),.learn_request(learn),.learn_slot(slot),
  .product_id(id),.status(status),.match_score(score),.learned_classes(learned),.enabled_classes(enabled),
  .learn_error(error),.result_frame_id(result_id),.record_counter(record_counter),
  .record_slot(record_slot),.record_view(record_view),.learn_cancel(cancel),.calibration_changed(changed),
  .sample_counts(sample_counts),.session_count(session),.sample_progress(progress),.learn_reason(reason),.recording(recording),.edge_strength(edge_strength),
  .background_ready(background_ready),.confirm_pulse(confirm_pulse));
 function [23:0] representative;input integer k;
  begin case(k)
   0:representative=24'h101010;1:representative=24'hdcdcdc;2:representative=24'h646464;
   3:representative=24'hdc1e1e;4:representative=24'hb4915a;5:representative=24'h1ec81e;
   6:representative=24'h1e1edc;default:representative=24'hc81ec8;
  endcase end
 endfunction
 task tick;begin @(posedge clk);#1;end endtask
 task start;begin @(negedge clk);fs=1;de=0;tick;@(negedge clk);fs=0;end endtask
 task request;input [2:0] which;
  begin @(negedge clk);slot=which;learn=1;tick;@(negedge clk);learn=0;repeat(4)tick;end
 endtask
 task do_cancel;begin @(negedge clk);cancel=1;tick;@(negedge clk);cancel=0;repeat(4)tick;end endtask
 // Five synthetic bottles are deliberately different color bins. Views 1/2
 // include top/bottom gray patches: each template is tested through RGB input.
 task pixels;input integer solid,view;input [31:0] source;
  begin
   fid=source;
   for(yy=0;yy<512;yy=yy+8)for(xx=0;xx<256;xx=xx+8)begin
    @(negedge clk);de=1;x=xx;y=yy;
    rgb=representative((view==1 && yy<128 || view==2 && yy>=384) ? 2:solid);
    if(view==3) rgb=representative(yy<16 && xx<256 ? solid:2);
    if(view==4) rgb=representative(yy/8*32+xx/8<white_points ? 1:3);
    edge_strength=edge_points>=0 ? ((yy/8*32+xx/8)<edge_points ? 32:0):edge_level;tick;
   end
   @(negedge clk);de=0;repeat(3)tick;start;
  end
 endtask
 task picture;input integer solid,view;input [31:0] source;
  begin pixels(solid,view,source);repeat(7000)tick;end
 endtask
 task fresh;input integer solid,view;
  begin picture(solid,view,next_id);next_id=next_id+1;end
 endtask
 task mixed_frame;input integer whites;
  begin
   fid=next_id;next_id=next_id+1;
   for(yy=0;yy<512;yy=yy+8)for(xx=0;xx<256;xx=xx+8)begin
    @(negedge clk);de=1;x=xx;y=yy;
    rgb=representative(yy<128 && xx<64 && yy/8*8+xx/8<whites ? 1:3);tick;
   end
   @(negedge clk);de=0;repeat(3)tick;start;repeat(7000)tick;
  end
 endtask
 task record_one;input integer which,solid,view;
  begin
   old_counter=record_counter;request(which);n=0;
   while(record_counter==old_counter && n<18)begin fresh(solid,view);n=n+1;end
   if(record_counter!=old_counter+1 || error || recording)
    $fatal(1,"record failed class%0d view%0d reason%0d state%0d progress%0d",which,view,reason,dut.state,progress);
   if(record_slot!=which || record_view!=(which==5 ? 0:view))$fatal(1,"record feedback mismatch");
  end
 endtask
 task acquire;input integer solid,view,want;
  begin
   n=0;fresh(solid,view);
   while((id!=want || status!=3 || score<95) && n<18)begin fresh(solid,view);n=n+1;end
   if(id!=want || status!=3 || score<95 || dut.best!=0)$fatal(1,"acquire id%0d expected%0d score%0d state%0d",id,want,score,dut.state);
  end
 endtask
 task remember_models;
  integer cc,vv,dd,base;
  begin
   mask_copy=enabled;
   for(cc=0;cc<5;cc=cc+1)begin
    base=cc*6+(dut.active_banks[cc] ? 3:0);
    for(vv=0;vv<3;vv=vv+1)for(dd=0;dd<128;dd=dd+1)
     model_copy[(cc*3+vv)*128+dd]=dut.u_store.templates[(base+vv)*128+dd];
   end
   for(dd=0;dd<128;dd=dd+1)bg_copy[dd]=dut.background[dut.background_bank*128+dd];
  end
 endtask
 task compare_models;input integer ignore_class,check_background;
  integer cc,vv,dd,base;
  begin
   if(enabled!=mask_copy)$fatal(1,"updating one model changed enabled mask");
   for(cc=0;cc<5;cc=cc+1)if(cc!=ignore_class)begin
    base=cc*6+(dut.active_banks[cc] ? 3:0);
    for(vv=0;vv<3;vv=vv+1)for(dd=0;dd<128;dd=dd+1)
     if(model_copy[(cc*3+vv)*128+dd]!==dut.u_store.templates[(base+vv)*128+dd])
      $fatal(1,"unrelated class %0d byte %0d was changed",cc,(vv*128+dd));
   end
   if(check_background)for(dd=0;dd<128;dd=dd+1)
    if(bg_copy[dd]!==dut.background[dut.background_bank*128+dd])$fatal(1,"class update changed background");
  end
 endtask
 initial begin
  repeat(5)tick;@(negedge clk);rst_n=1;repeat(5)tick;start;
  if(enabled!=0 || learned!=0 || sample_counts!=0)$fatal(1,"reset enabled photo seeds");
  cal=0;request(5);if(!error || reason!=1)$fatal(1,"WB prerequisite ignored");cal=1;
  request(0);if(!error || reason!=2)$fatal(1,"background prerequisite ignored");
  record_one(5,2,0);
  if(!background_ready || dut.background_edges!=0)$fatal(1,"background/color-edge statistics not committed");
  request(0);fresh(2,0);if(!error || reason!=3 || recording)$fatal(1,"empty sample accepted");
  // Strong edges prevent a near-background target being rejected during learning.
  edge_level=32;record_one(0,2,0);if(session!=1)$fatal(1,"edge-bearing target treated as empty");
  do_cancel;edge_level=0;
  // Color distance 32 is still empty without edges; 128 is deliberately above
  // the stricter 100 learning-empty gate while below the runtime 300 gate.
  old_counter=record_counter;request(0);n=0;
  while(record_counter==old_counter && n<18)begin fresh(3,3);n=n+1;end
  if(record_counter!=old_counter+1 || error)$fatal(1,"near-background nonempty learning rejected");
  do_cancel;
  record_one(0,3,0);
  if(session!=1 || enabled[0] || sample_counts!=0)$fatal(1,"partial class published");
  do_cancel;
  if(session!=0 || enabled!=0)$fatal(1,"partial cancellation published class");
  for(c=0;c<5;c=c+1)begin
   for(v=0;v<3;v=v+1)begin
    record_one(c,c+3,v);
    if(session!=v+1)$fatal(1,"three-image progress incorrect");
    if(v<2 && enabled[c])$fatal(1,"class enabled before three-image commit");
   end
   if(!enabled[c] || sample_counts[c*2+:2]!=3)$fatal(1,"class not enabled after commit");
   if(c==0)begin
    acquire(3,0,1);if(dut.learned_count!=1 || !dut.initial_good)$fatal(1,"single-class library not recognized");
    // Whole-RGB histograms at exact distances verify the tighter one-class
    // thresholds, without writing DUT distances or simulating score fixtures.
    white_points=433;fresh(3,4);
    if(dut.best!=1300 || !dut.hold_good || id!=1)$fatal(1,"single-class hold <=1300 boundary %0d",dut.best);
    white_points=434;for(i=0;i<10;i=i+1)fresh(3,4);
    if(dut.best!=1304 || dut.hold_good || id!=0)$fatal(1,"single-class hold accepted >1300");
    white_points=367;n=0;
    while(id!=1 && n<18)begin fresh(3,4);n=n+1;end
    if(dut.best!=1100 || !dut.initial_good || id!=1 || status!=3)$fatal(1,"single-class initial <=1100 boundary");
    fresh(2,0);fresh(2,0);if(id!=0)$fatal(1,"single-class background did not clear");
    white_points=368;for(i=0;i<12;i=i+1)fresh(3,4);
    if(dut.best!=1104 || dut.initial_good || id!=0)$fatal(1,"single-class initial accepted >1100");
   end
   if(c==1)begin acquire(4,0,2);if(dut.learned_count!=2)$fatal(1,"two-class library not recognized");end
   do_cancel;
  end
  if(enabled!=31 || sample_counts!=10'h3ff)$fatal(1,"five classes incomplete");
  // Background transactions update only their own double buffer and edge mean.
  remember_models;record_one(5,2,0);compare_models(-1,1);
  if(enabled!=31 || sample_counts!=10'h3ff)$fatal(1,"background update invalidated classes");
  // The background edge statistic averages the same eight distinct frames.
  request(5);for(i=0;i<4;i=i+1)fresh(2,0);
  for(i=1;i<=8;i=i+1)begin edge_points=i*2;fresh(2,0);end
  edge_points=-1;
  if(recording || dut.background_edges!=9)$fatal(1,"background edge eight-frame mean wrong %0d",dut.background_edges);
  compare_models(-1,1);
  record_one(5,2,0);compare_models(-1,1);
  // Even an exact background color must remain UNKNOWN rather than EMPTY
  // if its fresh edges provide evidence of a newly placed object.
  edge_level=32;for(i=0;i<3;i=i+1)fresh(2,0);
  if(status!=2 || id!=0)$fatal(1,"extra edges did not guard background rejection");
  edge_level=0;

  for(i=0;i<4;i=i+1)fresh(3,0);
  if(dut.votes<1 || id!=0)$fatal(1,"initial candidate setup failed");
  fresh(2,0);if(dut.votes!=0 || dut.vote_class!=0 || id!=0)$fatal(1,"empty frame did not break initial confirmation");
  fresh(3,0);if(dut.votes!=1 || id!=0)$fatal(1,"initial votes bridged an empty frame");
  // Independent views must all classify. A brief changed candidate must hold
  // the incumbent, while sustained replacements must eventually switch.
  acquire(3,0,1);
  before_confirmations=confirmations;
  for(i=0;i<12;i=i+1)fresh(3,0);
  if(confirmations!=before_confirmations)$fatal(1,"static confirmed item repeated confirmation pulse");
  fresh(4,0);fresh(4,0);fresh(4,0);
  fresh(2,0);if(id!=1 || dut.votes!=0 || dut.vote_class!=0)$fatal(1,"empty frame did not break switching confirmation");
  fresh(4,0);if(id!=1 || dut.votes!=1)$fatal(1,"switch votes bridged an empty frame");
  fresh(3,0);
  fresh(4,0);if(id!=1)$fatal(1,"single rival frame switched or cleared incumbent");
  fresh(3,0);if(id!=1)$fatal(1,"return to incumbent flickered");
  for(i=0;i<8;i=i+1)begin fresh(i[0] ? 4:3,0);if(id!=1)$fatal(1,"alternating candidates flickered");end
  for(c=0;c<5;c=c+1)for(v=0;v<3;v=v+1)acquire(c+3,v,c+1);
  // Blank background clears only after two fresh observations.
  fresh(2,0);if(id==0)$fatal(1,"one empty frame cleared result");
  fresh(2,0);if(id!=0 || status!=1)$fatal(1,"two empty frames did not clear");
  // Explicitly test both confirmation count and millisecond duration.
  fresh(3,0);start_ms=dut.candidate_since;
  for(i=0;i<5;i=i+1)begin fresh(3,0);if(id!=0)$fatal(1,"confirmed before 70ms");end
  if(dut.time_ms-start_ms>=70)$fatal(1,"test configuration cannot distinguish time gate");
  acquire(3,0,1);
  // Capture repeats cannot vote, and eventually expire a stale result.
  fresh(4,0);before_votes=dut.votes;
  before_confirmations=confirmations;
  for(i=0;i<4;i=i+1)begin picture(4,0,fid);if(dut.votes!=before_votes || confirmations!=before_confirmations)$fatal(1,"duplicate capture voted or emitted confirm event");end
  for(i=0;i<13;i=i+1)picture(4,0,fid);
  if(id!=0 || status!=0)$fatal(1,"stale capture not cleared");
  acquire(3,0,1);
  for(i=0;i<9;i=i+1)begin fresh(1,0);if(id!=1)$fatal(1,"short unknown sequence cleared result");end
  fresh(1,0);if(id!=0 || status!=2)$fatal(1,"ten unknown frames did not clear");
  acquire(3,0,1);
  // If background and object are indistinguishable in both color and edges,
  // it is unsafe to keep an ID. Preserve templates, but require fresh structure.
  remember_models;record_one(5,3,0);compare_models(-1,0);
  for(i=0;i<3;i=i+1)fresh(3,0);
  if(dut.bg_distance!=0 || status!=1 || id!=0)$fatal(1,"indistinguishable background retained class");
  edge_level=32;acquire(3,0,1);edge_level=0;
  record_one(5,2,0);compare_models(-1,1);acquire(3,0,1);
  // Replacement V1/V2 do not overwrite the old active group.
  remember_models;old_bank=dut.active_banks[0];
  record_one(0,6,0);record_one(0,6,1);
  if(dut.active_banks[0]!=old_bank)$fatal(1,"partial replacement changed bank");
  do_cancel;compare_models(-1,1);acquire(3,0,1);
  // Cancel while a third image is physically being committed. The old bank
  // must remain published even though the inactive RAM received some bytes.
  record_one(0,6,0);record_one(0,6,1);saved_counter=record_counter;request(0);n=0;
  while(dut.state!=10 && dut.state!=11 && dut.state!=12 && n<18)begin
   pixels(6,2,next_id);next_id=next_id+1;
   i=0;while(i<7000 && dut.state!=10 && dut.state!=11 && dut.state!=12)begin tick;i=i+1;end
   n=n+1;
  end
  if(dut.state!=10 && dut.state!=11 && dut.state!=12)$fatal(1,"did not reach commit for cancel test %0d",dut.state);
  do_cancel;
  if(dut.active_banks[0]!=old_bank || !enabled[0] || record_counter!=saved_counter)$fatal(1,"cancel damaged active group or emitted false save");
  compare_models(-1,1);
  acquire(3,0,1);
  // A complete update changes only the selected class, then can be restored.
  record_one(0,3,0);record_one(0,3,1);record_one(0,3,2);compare_models(0,1);
  acquire(3,0,1);
  // Duplicate learning frames do not add samples; requests while recording
  // are ignored, and an unstable/suspended scene reaches a wall-clock timeout.
  request(1);fresh(4,0);before_votes=progress;request(2);
  for(i=0;i<5;i=i+1)picture(4,0,fid);
  if(progress!=before_votes || dut.session_slot!=1)$fatal(1,"repeat input advanced training or retargeted it");
  repeat(510000)tick;
  if(recording || !error || reason!=4)$fatal(1,"learning wall-clock timeout missing");
  // Three stable observations precede the eight-frame mean. A changing
  // first-cell white count 2,4,...16 must average to 9, not the last value 16.
  request(0);for(i=0;i<4;i=i+1)fresh(3,0);
  if(progress!=0 || !recording)$fatal(1,"stability gate did not precede averaging");
  for(i=1;i<=8;i=i+1)begin
   mixed_frame(i*2);
   if(progress!=i)$fatal(1,"distinct-frame average progress wrong: %0d",progress);
  end
  if(recording || session!=1 || dut.staged[1]!=9 || dut.staged[3]!=119)
   $fatal(1,"eight-frame mean incorrect white%0d red%0d",dut.staged[1],dut.staged[3]);
  do_cancel;
  // Successful calibration invalidates all RAM validity, not just the result.
  @(negedge clk);changed=1;tick;@(negedge clk);changed=0;repeat(4)tick;
  if(enabled!=0 || sample_counts!=0 || dut.background_valid || id!=0)$fatal(1,"calibration did not invalidate templates");
  @(negedge clk);rst_n=0;repeat(4)tick;@(negedge clk);rst_n=1;repeat(4)tick;
  if(enabled!=0 || sample_counts!=0 || dut.background_valid)$fatal(1,"reset reloaded seeds");
  $display("PASS  progressive 1/2/5 classes, independent background/class models, edge-assisted empty guards, reliable-match priority, camera-only 3x5 atomic averaging, commit-cancel, time/count confirmation pulses, hysteresis and duplicate-ID rejection");$finish;
 end
 initial begin #200000000;$fatal(1,"watchdog");end
endmodule
