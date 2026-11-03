// Serialized 24x48 Census matcher. No video path latency is added.
module contest_label_matcher # (parameter ROI_X=512, ROI_Y=104)(
 input wire clk,rst_n,frame_start,de,input wire [11:0] x,y,
 input wire [23:0] rgb,input wire [31:0] capture_id,input wire capture_valid,
 input wire start,average_take,cancel,input wire [3:0] average_index,
 input wire [2:0] slot,input wire [1:0] view,
 input wire [4:0] active_banks,enabled,input wire [239:0] colors,
 output reg busy,done,output reg [79:0] distances,
 output reg [2:0] quality,output reg [15:0] structure_best);
 (* ram_style="bram" *) reg [7:0] gray[0:2303];
 (* ram_style="bram" *) reg [10:0] sums[0:1151];
 (* ram_style="bram" *) reg [15:0] current[0:1151];
 (* ram_style="bram" *) reg [15:0] templates[0:30719];
 reg [13:0] columns[0:23];
 reg bank,snapshot_bank,frame_ok,have_frame;
 reg [31:0] collected_id,snapshot_id;
 reg [10:0] pixels_written;
 wire [11:0] lx=x-(ROI_X+32),ly=y-(ROI_Y+64);
 wire inside=de && x>=ROI_X+32 && x<ROI_X+224 && y>=ROI_Y+64 && y<ROI_Y+448;
 wire [4:0] col=lx[7:3];
 wire [10:0] address=ly[8:3]*11'd24+col;
 wire [9:0] lum={2'd0,rgb[23:16]}+{1'd0,rgb[15:8],1'b0}+{2'd0,rgb[7:0]};
 wire [13:0] total=(lx[2:0]==0 && ly[2:0]==0 ? 14'd0:columns[col])+lum[9:2];
 reg [4:0] state;
 reg [10:0] index;
 reg [7:0] gray_q,center,neighbor;
 reg [10:0] sum_q,neighbor_sum;
 reg [15:0] live_q,template_q,code;
 reg [3:0] neighbor_index;
 reg [4:0] cx;reg [5:0] cy;
 reg averaging,save_template;reg [3:0] saved_average;
 reg [2:0] saved_slot,class_no;
 reg [1:0] saved_view,view_no;
 reg [4:0] saved_bank;
 reg [3:0] shift_no;
 reg signed [2:0] dx,dy;
 reg [15:0] errors,valid_bits;
 reg [13:0] structure_count;
 reg [19:0] brightness;
 reg [10:0] clipped;
 reg [31:0] dividend,remainder;
 reg [15:0] divisor,quotient;
 reg [5:0] div_bit;
 reg [15:0] normalized,joint,best_shift;
 wire [7:0] common=live_q[15:8]&template_q[15:8];
 wire [7:0] mismatch=(live_q[7:0]^template_q[7:0])&common;
 function [3:0] pop;
 input [7:0] a;
 begin pop={3'd0,a[0]}+a[1]+a[2]+a[3]+a[4]+a[5]+a[6]+a[7];end
 endfunction
 reg [10:0] neighbor_address,shift_address;
 reg [15:0] template_address;
 reg [15:0] template_read_address;reg [10:0] current_read_address;
 reg [4:0] physical_bank;
 always @(*) begin
  case(neighbor_index)
   0:neighbor_address=index-25;1:neighbor_address=index-24;2:neighbor_address=index-23;
   3:neighbor_address=index-1;4:neighbor_address=index+1;
   5:neighbor_address=index+23;6:neighbor_address=index+24;default:neighbor_address=index+25;
  endcase
  dx=shift_no==0 || shift_no==3 || shift_no==6 ? -1:shift_no==2 || shift_no==5 || shift_no==8 ? 1:0;
  dy=shift_no<3 ? -1:shift_no>=6 ? 1:0;
  case(shift_no)
   0:shift_address=index-25;1:shift_address=index-24;2:shift_address=index-23;
   3:shift_address=index-1;4:shift_address=index;5:shift_address=index+1;
   6:shift_address=index+23;7:shift_address=index+24;default:shift_address=index+25;
  endcase
  physical_bank=class_no*6+(active_banks[class_no] ? 3:0)+view_no;
  template_address={physical_bank,10'd0}+(cy-1'b1)*22+cx-1'b1;
 end
 // Synchronous memory ports keep storage in ERAM and arithmetic off read muxes.
 always @(posedge clk)begin
  if(inside)begin
   columns[col]<=total;
   if(lx[2:0]==7 && ly[2:0]==7)gray[(bank ? 1152:0)+address]<=total[13:6];
  end
  begin
   gray_q<=gray[(snapshot_bank ? 1152:0)+(state==7 ? neighbor_address:index)];
   sum_q<=sums[state==7 ? neighbor_address:index];
  end
  if(state==3)sums[index]<=saved_average==0 ? {3'd0,gray_q}:sum_q+gray_q;
  current_read_address<=shift_address;template_read_address<=template_address;
  live_q<=current[current_read_address];
  template_q<=templates[template_read_address];
  if(state==9)begin
   if(save_template)begin
    if(cx>0 && cx<23 && cy>0 && cy<47)templates[{saved_bank,10'd0}+(cy-1'b1)*22+cx-1'b1]<=code;
   end
   else current[index]<=code;
  end
 end
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   bank<=0;snapshot_bank<=0;frame_ok<=0;have_frame<=0;collected_id<=0;snapshot_id<=0;pixels_written<=0;
   state<=0;busy<=0;done<=0;quality<=0;distances<={80{1'b1}};structure_best<=16'hffff;
   index<=0;cx<=0;cy<=0;neighbor_index<=0;code<=0;structure_count<=0;brightness<=0;clipped<=0;
   saved_average<=0;averaging<=0;save_template<=0;class_no<=0;view_no<=0;shift_no<=0;
   errors<=0;valid_bits<=0;best_shift<=16'hffff;
   saved_slot<=0;saved_view<=0;saved_bank<=0;center<=0;neighbor<=0;
   dividend<=0;remainder<=0;divisor<=0;quotient<=0;div_bit<=0;normalized<=0;joint<=0;
  end else begin
   done<=0;
   if(inside)begin
    if(lx==0 && ly==0)begin frame_ok<=capture_valid;collected_id<=capture_id;end
    else if(!capture_valid || collected_id!=capture_id)frame_ok<=0;
    if(lx[2:0]==7 && ly[2:0]==7)pixels_written<=pixels_written+1'b1;
   end
   if(frame_start)begin
    pixels_written<=0;frame_ok<=0;
    if(pixels_written==1152 && frame_ok && !busy)begin
     snapshot_bank<=bank;bank<=!bank;have_frame<=1;snapshot_id<=collected_id;
    end
   end
   if(cancel)begin state<=0;busy<=0;done<=0;have_frame<=0;end
   else case(state)
    0:if((start || average_take) && have_frame)begin
     busy<=1;quality<=0;index<=0;cx<=0;cy<=0;structure_count<=0;brightness<=0;clipped<=0;
     saved_average<=average_index;averaging<=average_take;save_template<=average_take && average_index==7;
     saved_slot<=slot;saved_view<=view;
     saved_bank<=slot*6+(active_banks[slot] ? 0:3)+view;
     state<=average_take ? 1:4;
     if(start)begin distances<={80{1'b1}};structure_best<=16'hffff;end
    end
    1:state<=2;
    2:state<=3;
    3:begin
     if(index==1151)begin
      index<=0;cx<=0;cy<=0;
      if(saved_average==7)state<=4;else begin busy<=0;done<=1;state<=0;end
     end else begin index<=index+1'b1;state<=1;end
    end
    4:state<=5;
    5:begin
     center<=averaging ? (sum_q+11'd4)>>3:gray_q;
     brightness<=brightness+(averaging ? (sum_q+11'd4)>>3:gray_q);
     if((averaging ? (sum_q+11'd4)>>3:gray_q)>=248)clipped<=clipped+1'b1;
     neighbor_index<=0;code<=0;
     state<=cx==0 || cx==23 || cy==0 || cy==47 ? 9:6;
    end
    6:state<=7;
    7:state<=8;
    8:begin
     // Training compares the same eight-frame averaged pixels as inference.
     neighbor<=averaging ? (sum_q+11'd4)>>3:gray_q;
     state<=17;
    end
    17:begin
     code[neighbor_index]<=neighbor>=center;
     code[8+neighbor_index]<=neighbor>=center+9'd6 || {1'b0,neighbor}+9'd6<=center;
     if(neighbor>=center+9'd6 || {1'b0,neighbor}+9'd6<=center)structure_count<=structure_count+1'b1;
     if(neighbor_index==7)state<=9;else begin neighbor_index<=neighbor_index+1'b1;state<=6;end
    end
    9:begin
     if(index==1151)begin
      quality<=brightness+center<1152*32 ? 1:clipped+(center>=248 ? 1:0)>115 ? 2:structure_count<384 ? 3:0;
      if(save_template)begin busy<=0;done<=1;state<=0;end
      else begin class_no<=0;view_no<=0;shift_no<=0;index<=25;cx<=1;cy<=1;
       errors<=0;valid_bits<=0;best_shift<=16'hffff;state<=10;end
     end else begin
      index<=index+1'b1;
      if(cx==23)begin cx<=0;cy<=cy+1'b1;end else cx<=cx+1'b1;
      state<=4;
     end
    end
    10:if(!enabled[class_no])state<=16;else state<=11;
    11:state<=12;
    12:state<=13;
    13:begin
     errors<=errors+pop(mismatch);valid_bits<=valid_bits+pop(common);
     if(cx==22 && cy==46)begin state<=14;end
     else begin
      if(cx==22)begin cx<=1;cy<=cy+1'b1;index<=index+3;end
      else begin cx<=cx+1'b1;index<=index+1'b1;end
      state<=11;
     end
    end
    14:begin
     dividend<={6'd0,errors,10'd0};divisor<=valid_bits;remainder<=0;quotient<=0;div_bit<=31;
     state<=18;
    end
    18:begin
     if(((remainder<<1)|((dividend>>div_bit)&1))>=divisor)begin
      remainder<=((remainder<<1)|((dividend>>div_bit)&1))-divisor;
      if(div_bit<16)quotient[div_bit]<=1;
     end else remainder<=(remainder<<1)|((dividend>>div_bit)&1);
     if(div_bit==0)state<=19;else div_bit<=div_bit-1'b1;
    end
    19:begin
     normalized<=valid_bits<384 ? 16'hffff:quotient;
     state<=20;
    end
    20:begin
     joint<=normalized>350 || colors[(class_no*3+view_no)*16+:16]>2400 ? 16'hffff:
       normalized*3+(colors[(class_no*3+view_no)*16+:16]>>3);
     if(normalized<structure_best)structure_best<=normalized;
     state<=15;
    end
    15:begin
     if(joint<best_shift)best_shift<=joint;
     if(shift_no==8)begin
      if((joint<best_shift ? joint:best_shift)<distances[class_no*16+:16])
       distances[class_no*16+:16]<=joint<best_shift ? joint:best_shift;
      state<=16;
     end else begin shift_no<=shift_no+1'b1;index<=25;cx<=1;cy<=1;errors<=0;valid_bits<=0;state<=10;end
    end
    16:begin
     shift_no<=0;index<=25;cx<=1;cy<=1;errors<=0;valid_bits<=0;best_shift<=16'hffff;
     if(view_no==2 || !enabled[class_no])begin
      view_no<=0;
      if(class_no==4)begin busy<=0;done<=1;state<=0;end
      else begin class_no<=class_no+1'b1;state<=10;end
     end else begin view_no<=view_no+1'b1;state<=10;end
    end
    default:begin state<=0;busy<=0;end
   endcase
  end
 end
endmodule
