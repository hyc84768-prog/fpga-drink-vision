`timescale 1ns/1ps
module tb_label_matcher;
 reg clk=0,rst=0,fs=0,de=0,start=0,take=0,cancel=0;
 reg [11:0] x=0,y=0;reg [23:0] rgb=0;reg [31:0] fid=0;
 reg [3:0] avg=0;reg [2:0] slot=0;reg [1:0] view=0;
 reg [4:0] banks=0,enabled=0;
 wire busy,done;wire [79:0] distances;wire [2:0] quality;wire [15:0] structure_best;
 integer xx,yy,k,c,v,n,luma,cycles;
 always #5 clk=~clk;
 always @(posedge clk)if(rst && dut.state==19 && dut.valid_bits!=0)begin
  if(dut.quotient!==(({16'd0,dut.errors}<<10)/dut.valid_bits))
   $fatal(1,"serialized normalized distance disagrees with independent integer division");
 end
 contest_label_matcher #(.ROI_X(0),.ROI_Y(0)) dut(.clk(clk),.rst_n(rst),
 .frame_start(fs),.de(de),.x(x),.y(y),.rgb(rgb),.capture_id(fid),.capture_valid(1'b1),
 .start(start),.average_take(take),.cancel(cancel),.average_index(avg),.slot(slot),.view(view),
 .active_banks(banks),.enabled(enabled),.colors(240'd0),.busy(busy),.done(done),
 .distances(distances),.quality(quality),.structure_best(structure_best));
 task tick;begin @(posedge clk);#1;end endtask
 task frame;input integer pattern,offset,scale;
 begin
  fid=fid+1;
  for(yy=64;yy<448;yy=yy+1)for(xx=32;xx<224;xx=xx+1)begin
   @(negedge clk);x=xx;y=yy;de=1;
   if(pattern==0)luma=(((xx-32+offset)/16)%2)==0 ? 40:180;
   else if(pattern==1)luma=(((yy-64+offset)/16)%2)==0 ? 40:180;
   else luma=pattern==2 ? 8:255;
   luma=luma*scale/100;rgb={luma[7:0],luma[7:0],luma[7:0]};tick;
  end
  @(negedge clk);de=0;fs=1;tick;@(negedge clk);fs=0;repeat(3)tick;
 end endtask
 task wait_done;
 begin
  cycles=0;while(!done && cycles<1000000)begin tick;cycles=cycles+1;end
  if(!done)$fatal(1,"matcher timeout state %0d",dut.state);
  tick;
 end endtask
 task sample;
 begin @(negedge clk);take=1;tick;@(negedge clk);take=0;wait_done;end endtask
 task match_frame;input integer pattern,offset,scale;
 begin frame(pattern,offset,scale);@(negedge clk);start=1;tick;@(negedge clk);start=0;wait_done;end endtask
 initial begin
  repeat(4)tick;@(negedge clk);rst=1;
  for(c=0;c<2;c=c+1)begin
   slot=c;
   for(v=0;v<3;v=v+1)begin
    view=v;
    for(k=0;k<8;k=k+1)begin avg=k;frame(c,0,100);sample;end
    if(quality!=0)$fatal(1,"valid training rejected %0d",quality);
   end
   banks[c]=1;enabled[c]=1;
  end
  match_frame(0,0,100);
  if(quality!=0 || distances[15:0]!=0 || distances[31:16]<distances[15:0]+240)
   $fatal(1,"same colors different structure not separated: %h",distances);
  match_frame(1,8,70);
  if(quality!=0 || distances[31:16]!=0 || distances[15:0]<distances[31:16]+240)
   $fatal(1,"translated darker horizontal label failed: %h q%0d sb%0d valid%0d",distances,quality,structure_best,dut.valid_bits);
  match_frame(2,0,100);if(quality!=1)$fatal(1,"dark frame not rejected");
  match_frame(3,0,100);if(quality!=2)$fatal(1,"clipped frame not rejected");
  @(negedge clk);start=1;tick;@(negedge clk);start=0;repeat(10)tick;
  cancel=1;tick;cancel=0;tick;if(busy)$fatal(1,"cancel left matcher busy");
  $display("PASS label RGB capture, eight-frame averaging, two three-view classes, structure separation, nine-shift search, brightness, clipping and cancel");$finish;
 end
 initial begin #300000000;$fatal(1,"watchdog");end
endmodule
