// camera-only transactional learning, three views/class, stable results.
module contest_bottle_classifier #(
 parameter integer ROI_X=512,ROI_Y=104,MAX_DISTANCE=1650,MIN_MARGIN=240,
 parameter integer CONFIRM_FRAMES=6,STALE_FRAMES=120,
 parameter integer CLOCK_HZ=75000000,CONFIRM_MS=300,LEARN_TIMEOUT_MS=3000,
 parameter integer SWITCH_FRAMES=12,SWITCH_MS=600,LOSS_MS=400,TEMPORAL_FILTER=1,LABEL_ENABLE=0,MANUAL_IDENTIFY=0
)(input wire clk,rst_n,frame_start,de,
 input wire [11:0] x,y,input wire [23:0] rgb,
 input wire [31:0] capture_id,input wire capture_valid,calibration_ok,
 input wire learn_request,input wire [2:0] learn_slot,
 output reg [2:0] product_id,status,output reg [6:0] match_score,
 output reg [4:0] learned_classes,output wire [4:0] enabled_classes,
 output reg learn_error,output reg [31:0] result_frame_id,
 output reg [7:0] record_counter,output reg [2:0] record_slot,output reg [1:0] record_view,
 input wire learn_cancel,calibration_changed,
 output reg [9:0] sample_counts,output reg [1:0] session_count,
 output reg [3:0] sample_progress,output reg [2:0] learn_reason,output reg recording,
 input wire [7:0] edge_strength,output wire background_ready,output reg confirm_pulse,
 output wire [15:0] debug_background,debug_best,debug_incumbent,
 output wire [11:0] debug_edges,output wire [7:0] debug_reference,
 input wire identify_request,identify_cancel,
 output reg identify_busy,identify_done,output reg [2:0] identify_reason,
 output wire [15:0] debug_structure,debug_color,debug_margin);
 // Status WAIT/EMPTY/UNKNOWN/KNOWN/LEARNING/NEED_WB/NEED_BG/NEED_CLASSES.
 localparam IDLE=0,SCAN_READ=1,SCAN_WAIT=2,SCAN_ADD=3,
  AVG_READ=4,AVG_WAIT=5,AVG_ADD=6,SAVE_READ=7,SAVE_WAIT=8,SAVE_WRITE=9,
  COMMIT_READ=10,COMMIT_WAIT=11,COMMIT_WRITE=12,
  SCORE_READ=13,SCORE_WAIT=14,SCORE_ADD=15,FINAL=16,RANK_INIT=17,RANK=18;
 localparam integer MS_CYCLES=CLOCK_HZ/1000<1 ? 1:CLOCK_HZ/1000;
 localparam integer MS_WIDTH=MS_CYCLES<2 ? 1:$clog2(MS_CYCLES);
 reg [MS_WIDTH-1:0] ms_divider;
 reg [15:0] time_ms,learn_since,candidate_since;
 reg [15:0] loss_since;
 reg [2:0] confirmed_class;
 reg [1:0] recovery_frames;
 wire [15:0] loss_elapsed=time_ms-loss_since;
 wire [15:0] learn_elapsed=time_ms-learn_since,candidate_elapsed=time_ms-candidate_since;
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin ms_divider<=0;time_ms<=0;end
  else if(ms_divider==MS_CYCLES-1) begin ms_divider<=0;time_ms<=time_ms+1'b1;end
  else ms_divider<=ms_divider+1'b1;
 end
 reg [4:0] state;
 reg [6:0] dimension;
 reg [7:0] counts[0:127],snapshot[0:127],previous[0:127],background[0:255];
 reg [7:0] filtered[0:127],filter_q;
 reg filter_valid,use_filtered;
 reg [10:0] averages[0:127];
 reg [7:0] staged[0:383];
 reg [7:0] snapshot_q,previous_q,background_q,staged_q;
 wire [9:0] filter_sum={2'd0,filter_q}+{1'd0,filter_q,1'b0}+{2'd0,snapshot_q}+10'd2;
 reg [10:0] average_q;
 reg [15:0] class_distance[0:4];
 reg [15:0] distance,bg_distance,temporal_distance;
 reg [4:0] active_banks;
 reg [2:0] class_index,session_slot,pending_slot;
 reg [1:0] view_index,commit_view;
 reg session_valid,pending_learn,previous_valid,background_valid,background_bank;
 reg [2:0] stable_count;
 reg [3:0] average_count,votes,bad_frames;
 reg [1:0] empty_frames;
 reg [2:0] vote_class;
 reg [11:0] samples,edge_count,snapshot_edges,background_edges;
 reg [14:0] edge_average_sum;
 reg [19:0] luma_sum;
 reg [7:0] snapshot_mean,previous_mean;
 reg [31:0] collecting_id,last_id,snapshot_id;
 reg collection_valid,seen_id;
 reg [7:0] stale;
 wire [11:0] local_x=x-ROI_X,local_y=y-ROI_Y;
 wire sample=de && x>=ROI_X && x<ROI_X+256 && y>=ROI_Y && y<ROI_Y+512 &&
  local_x[2:0]==0 && local_y[2:0]==0;
 wire [7:0] r=rgb[23:16],g=rgb[15:8],b=rgb[7:0];
 wire [9:0] pixel_luma={2'b0,r}+{1'b0,g,1'b0}+{2'b0,b};
 wire [7:0] maximum=r>g ? (r>b ? r:b):(g>b ? g:b);
 wire [7:0] minimum=r<g ? (r<b ? r:b):(g<b ? g:b);
 reg [7:0] light_reference;
 reg [16:0] reference_sum;
 reg [9:0] reference_samples;
 reg [31:0] reference_capture;
 reg reference_consistent;
 wire reference_sample=de && local_y<512 && local_y[2:0]==0 && x[2:0]==(ROI_X%8) &&
  ((ROI_X>=32 && x>=ROI_X-32 && x<ROI_X) || (x>=ROI_X+256 && x<ROI_X+288));
 wire [8:0] chroma={1'b0,maximum}-{1'b0,minimum};
 wire [7:0] color_reference=LABEL_ENABLE ? 8'd128:light_reference;
 wire [9:0] white_threshold={2'd0,color_reference}+{4'd0,color_reference[7:2]};
 reg [2:0] color_bin;
 always @(*) begin
  // Relative thresholds track neutral side rails, without a pixel divider.
  // Hue ratios remain invariant to a common exposure gain until clipping.
  if(maximum<16 || {maximum,1'b0}<{1'b0,(LABEL_ENABLE ? 8'd128:light_reference)}) color_bin=0;
  else if({chroma,2'b0}<{3'd0,maximum}) color_bin={2'd0,minimum}>=white_threshold ? 1:2;
  else if({r,2'b0}>{1'b0,g,2'b0}+{3'b0,g} && {r,2'b0}>{1'b0,b,2'b0}+{3'b0,b}) color_bin=3;
  else if(r>=g && {1'b0,g}>={1'b0,b}+{5'd0,maximum[7:4]}) color_bin=4;
  else if(g>r && g>=b) color_bin=5;
  else if(b>r && b>g) color_bin=6;
  else color_bin=7;
 end
 wire [6:0] feature_index={local_y[8:7],local_x[7:6],color_bin};
 reg feature_pending;
 reg [6:0] feature_index_d;
 wire [7:0] template_data;
 wire [4:0] physical_read_bank=class_index*5'd6+(active_banks[class_index] ? 5'd3:5'd0)+view_index;
 wire [4:0] physical_write_bank=session_slot<5 ?
  session_slot*5'd6+(active_banks[session_slot] ? 5'd0:5'd3)+commit_view:5'd0;
 wire [11:0] read_address={physical_read_bank,dimension},write_address={physical_write_bank,dimension};
 bottle_template_store u_store(.clk(clk),.seed_address(11'd0),.seed_data(),
  .read_address(read_address),.read_data(template_data),.write_enable(state==COMMIT_WRITE),
  .write_address(write_address),.write_data(staged_q));
 wire [8:0] delta=snapshot_q>template_data ? snapshot_q-template_data:template_data-snapshot_q;
 wire [8:0] bg_delta=snapshot_q>background_q ? snapshot_q-background_q:background_q-snapshot_q;
 wire [8:0] temporal_delta=snapshot_q>previous_q ? snapshot_q-previous_q:previous_q-snapshot_q;
 wire center_column=dimension[4]^dimension[3];
 wire [9:0] weighted_delta=center_column ? {delta,1'b0}:{1'b0,delta};
 wire [16:0] distance_next={1'b0,distance}+weighted_delta;
 wire [16:0] bg_next={1'b0,bg_distance}+bg_delta;
 wire [16:0] temporal_next={1'b0,temporal_distance}+temporal_delta;
 wire [8:0] mean_delta=snapshot_mean>=previous_mean ? snapshot_mean-previous_mean:previous_mean-snapshot_mean;
 wire stable_now=previous_valid && temporal_next<=200 && mean_delta<=4;
 wire [11:0] edge_tolerance=background_edges>=64 ? background_edges>>2:12'd16;
 wire no_new_edges={1'b0,snapshot_edges}<={1'b0,background_edges}+{1'b0,edge_tolerance};
 wire learning_empty=background_valid && bg_next<100 && no_new_edges;
 wire background_empty=background_valid && bg_distance<300 && no_new_edges;
 wire [15:0] rounded_edge_average={1'b0,edge_average_sum}+16'd4;
 wire [10:0] average_next=average_count==0 ? {3'd0,snapshot_q}:average_q+snapshot_q;
 wire [11:0] rounded_average={1'b0,average_q}+12'd4;
 wire [8:0] staged_write_index={session_count,dimension},staged_read_index={commit_view,dimension};
 reg [15:0] best,second,incumbent;
 reg [2:0] best_class,rank_index;
 wire [2:0] learned_count={2'd0,learned_classes[0]}+{2'd0,learned_classes[1]}+
  {2'd0,learned_classes[2]}+{2'd0,learned_classes[3]}+{2'd0,learned_classes[4]};
 wire initial_good=best_class!=0 && (learned_count==1 ? best<=1100:
  best<=MAX_DISTANCE && {1'b0,second}>={1'b0,best}+MIN_MARGIN);
 wire switch_good=learned_count>=2 && initial_good && best_class!=confirmed_class && best<=1350 &&
  {1'b0,second}>={1'b0,best}+17'd360 && {1'b0,incumbent}>={1'b0,best}+17'd240;
 wire hold_good=confirmed_class!=0 && incumbent<=(learned_count==1 ? 1300:1800);
 // An independently convincing empty scene must defeat the old class hold.
 // A target close to the background can still win if its match is better or
 // it adds structure. An indistinguishable background is never a valid ID.
 wire empty_evidence=background_empty && {1'b0,bg_distance}<={1'b0,best}+17'd96;
 // Match quality, not confidence: one point per 32 weighted-L1 counts.
 function [6:0] score_of;
  input [15:0] value;
  begin score_of=value>=3200 ? 0:7'd100-(value>>5);end
 endfunction
 wire [8:0] score_sum={2'b0,match_score}+({2'b0,match_score}<<1)+score_of(incumbent)+9'd2;
 reg [239:0] view_distances;
 wire label_busy,label_done;wire [79:0] label_distances;wire [2:0] label_quality;
 wire label_start=LABEL_ENABLE && state==RANK_INIT;
 wire label_average=LABEL_ENABLE && state==AVG_ADD && dimension==127 && session_slot<5;
 wire [15:0] label_structure;
 assign debug_structure=label_structure;
 generate if(LABEL_ENABLE)begin:LABEL
 contest_label_matcher #(.ROI_X(ROI_X),.ROI_Y(ROI_Y)) u_label(
 .clk(clk),.rst_n(rst_n),.frame_start(frame_start),.de(de),.x(x),.y(y),.rgb(rgb),
 .capture_id(capture_id),.capture_valid(capture_valid),.start(label_start),.average_take(label_average),
 .cancel(calibration_changed || learn_cancel),.average_index(average_count),.slot(session_slot),.view(session_count),
 .active_banks(active_banks),.enabled(learned_classes),.colors(view_distances),
 .busy(label_busy),.done(label_done),.distances(label_distances),.quality(label_quality),.structure_best(label_structure));
 end else begin:NOLABEL
 assign label_busy=0;assign label_done=0;assign label_distances=0;assign label_quality=0;assign label_structure=0;
 end endgenerate
 reg [15:0] identify_since;
 wire [15:0] identify_elapsed=time_ms-identify_since;
 reg [3:0] identify_frames,identify_stable;
 reg [3:0] identify_votes[0:4];
 reg [2:0] identify_winner;
 reg [3:0] identify_max;
 reg [6:0] identify_score;
 reg frame_stable;
 wire [15:0] cv0=best_class==0 ? 16'hffff:view_distances[((best_class-1)*3)*16+:16];
 wire [15:0] cv1=best_class==0 ? 16'hffff:view_distances[((best_class-1)*3+1)*16+:16];
 wire [15:0] cv2=best_class==0 ? 16'hffff:view_distances[((best_class-1)*3+2)*16+:16];
 assign debug_color=cv0<cv1 ? (cv0<cv2 ? cv0:cv2):(cv1<cv2 ? cv1:cv2);
 assign debug_margin=best==16'hffff ? 0:second-best;
 assign enabled_classes=learned_classes;
 assign background_ready=background_valid;
 assign debug_background=bg_distance;assign debug_best=best;assign debug_incumbent=incumbent;
 assign debug_edges=snapshot_edges;assign debug_reference=light_reference;
 // Registered reads separate memory selection from distance/average arithmetic.
 always @(posedge clk) begin
  if(state==SCAN_READ || state==AVG_READ) snapshot_q<=snapshot[dimension];
  if(state==SCORE_READ)snapshot_q<=use_filtered ? filtered[dimension]:snapshot[dimension];
  if(state==SCAN_READ)filter_q<=filtered[dimension];
  if(state==SCAN_READ) begin previous_q<=previous[dimension];background_q<=background[{background_bank,dimension}];end
  if(state==AVG_READ || state==SAVE_READ) average_q<=averages[dimension];
  if(state==SCAN_ADD) previous[dimension]<=snapshot_q;
  if(state==SCAN_ADD && !recording)filtered[dimension]<=filter_valid ? filter_sum[9:2]:snapshot_q;
  if(state==AVG_ADD) averages[dimension]<=average_next;
  if(state==SAVE_WRITE && session_slot==5) background[{!background_bank,dimension}]<=rounded_average[10:3];
  if(state==SAVE_WRITE && session_slot<5) staged[staged_write_index]<=rounded_average[10:3];
  if(state==COMMIT_READ) staged_q<=staged[staged_read_index];
 end
 integer i;
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
   identify_busy<=0;identify_done<=0;identify_reason<=0;identify_since<=0;
   identify_frames<=0;identify_stable<=0;identify_winner<=0;identify_max<=0;identify_score<=0;frame_stable<=0;
   view_distances<=0;for(i=0;i<5;i=i+1)identify_votes[i]<=0;
   state<=IDLE;dimension<=0;class_index<=0;view_index<=0;commit_view<=0;
   filter_valid<=0;use_filtered<=0;confirmed_class<=0;recovery_frames<=0;loss_since<=0;
   light_reference<=128;reference_sum<=0;reference_samples<=0;reference_capture<=0;reference_consistent<=0;
   learned_classes<=0;active_banks<=0;sample_counts<=0;session_count<=0;sample_progress<=0;
   session_valid<=0;session_slot<=0;pending_slot<=0;pending_learn<=0;
   product_id<=0;status<=0;match_score<=0;learn_error<=0;learn_reason<=0;recording<=0;
   previous_valid<=0;background_valid<=0;background_bank<=0;distance<=0;bg_distance<=0;temporal_distance<=0;
   stable_count<=0;average_count<=0;votes<=0;vote_class<=0;bad_frames<=0;empty_frames<=0;
   samples<=0;edge_count<=0;snapshot_edges<=0;background_edges<=0;edge_average_sum<=0;
   luma_sum<=0;snapshot_mean<=0;previous_mean<=0;confirm_pulse<=0;
   collecting_id<=0;last_id<=0;snapshot_id<=0;result_frame_id<=0;collection_valid<=0;seen_id<=0;
   stale<=0;candidate_since<=0;learn_since<=0;
   record_counter<=0;record_slot<=0;record_view<=0;feature_pending<=0;feature_index_d<=0;
   best<=16'hffff;second<=16'hffff;incumbent<=16'hffff;best_class<=0;rank_index<=0;
   for(i=0;i<128;i=i+1) begin counts[i]<=0;snapshot[i]<=0;end
   for(i=0;i<5;i=i+1) class_distance[i]<=16'hffff;
  end else begin
   if(reference_sample)begin
    if(reference_samples<512)begin reference_sum<=reference_sum+pixel_luma[9:2];reference_samples<=reference_samples+1'b1;end
    if(reference_samples==0)begin reference_capture<=capture_id;reference_consistent<=capture_valid;end
    else if(!capture_valid || capture_id!=reference_capture)reference_consistent<=0;
   end
   identify_done<=0;
   if(MANUAL_IDENTIFY && identify_request && !identify_busy && !recording)begin
    if(!calibration_ok || !background_valid || learned_classes==0)begin
     identify_busy<=0;identify_done<=1;identify_reason<=6;
     status<=!calibration_ok ? 5:!background_valid ? 6:7;
    end else begin
    identify_busy<=1;identify_since<=time_ms;identify_frames<=0;identify_stable<=0;
    identify_winner<=0;identify_max<=0;identify_reason<=0;identify_score<=0;
    for(i=0;i<5;i=i+1)identify_votes[i]<=0;
    end
   end
   if(MANUAL_IDENTIFY && identify_busy && identify_elapsed>=2000)begin
    identify_busy<=0;identify_done<=1;identify_reason<=4;product_id<=0;status<=2;match_score<=0;
   end
   if(identify_cancel || calibration_changed || learn_cancel || learn_request)begin identify_busy<=0;identify_reason<=0;end
   confirm_pulse<=0;
   feature_pending<=sample;
   if(sample) feature_index_d<=feature_index;
   if(feature_pending) counts[feature_index_d]<=counts[feature_index_d]+1'b1;
   if(sample) begin
    samples<=samples+1'b1;luma_sum<=luma_sum+pixel_luma[9:2];
    if(edge_strength>16) edge_count<=edge_count+1'b1;
    if(local_x==0 && local_y==0) begin collecting_id<=capture_id;collection_valid<=capture_valid;end
    else if(!capture_valid || capture_id!=collecting_id) collection_valid<=0;
   end
   if(learn_request && !recording && !pending_learn) begin
    pending_learn<=1;pending_slot<=learn_slot;learn_error<=0;learn_reason<=0;
   end
   if(frame_start) begin
    reference_sum<=0;reference_samples<=0;reference_consistent<=0;
    if(reference_samples==512 && reference_consistent && reference_sum[16:9]>=32 && reference_sum[16:9]<=240)
     light_reference<=reference_sum[16:9];
    for(i=0;i<128;i=i+1) counts[i]<=0;
    samples<=0;edge_count<=0;luma_sum<=0;collection_valid<=0;
    if(stale<STALE_FRAMES) stale<=stale+1'b1;
    if(stale>=STALE_FRAMES-1) begin
     product_id<=0;status<=0;match_score<=0;votes<=0;vote_class<=0;bad_frames<=0;
     confirmed_class<=0;filter_valid<=0;use_filtered<=0;recovery_frames<=0;empty_frames<=0;
    end
    if(state==IDLE && !pending_learn && samples==2048 && !feature_pending && collection_valid &&
       (!seen_id || collecting_id!=last_id)) begin
     last_id<=collecting_id;seen_id<=1;stale<=0;
     if(!calibration_ok) begin status<=5;product_id<=0;confirmed_class<=0;filter_valid<=0;votes<=0;vote_class<=0;match_score<=0;end
     else begin
      for(i=0;i<128;i=i+1) snapshot[i]<=counts[i];
      for(i=0;i<5;i=i+1) class_distance[i]<=16'hffff;
      snapshot_mean<=luma_sum[18:11];snapshot_edges<=edge_count;snapshot_id<=collecting_id;
      dimension<=0;bg_distance<=0;temporal_distance<=0;distance<=0;state<=SCAN_READ;
     end
    end
   end
   if(calibration_changed) begin
    confirmed_class<=0;filter_valid<=0;use_filtered<=0;recovery_frames<=0;
    light_reference<=128;reference_sum<=0;reference_samples<=0;reference_consistent<=0;
    learned_classes<=0;sample_counts<=0;background_valid<=0;previous_valid<=0;
    session_valid<=0;session_count<=0;sample_progress<=0;recording<=0;pending_learn<=0;
    learn_error<=0;learn_reason<=0;state<=IDLE;collection_valid<=0;
    product_id<=0;status<=6;match_score<=0;votes<=0;vote_class<=0;bad_frames<=0;empty_frames<=0;
   end else if(learn_cancel) begin
    confirmed_class<=0;filter_valid<=0;use_filtered<=0;recovery_frames<=0;
    recording<=0;pending_learn<=0;session_valid<=0;session_count<=0;sample_progress<=0;
    learn_reason<=5;learn_error<=0;state<=IDLE;previous_valid<=0;
    product_id<=0;match_score<=0;votes<=0;vote_class<=0;bad_frames<=0;status<=0;
   end else if(recording && (!calibration_ok || learn_elapsed>=LEARN_TIMEOUT_MS)) begin
    recording<=0;state<=IDLE;sample_progress<=0;stable_count<=0;average_count<=0;
    learn_error<=1;learn_reason<=calibration_ok ? 3'd4:3'd1;status<=calibration_ok ? 3'd0:3'd5;
   end else begin
    case(state)
     IDLE: if(pending_learn) begin
      pending_learn<=0;
      if(!calibration_ok) begin learn_error<=1;learn_reason<=1;status<=5;end
      else if(pending_slot<5 && !background_valid) begin learn_error<=1;learn_reason<=2;status<=6;end
      else if(pending_slot<=5) begin
       confirmed_class<=0;filter_valid<=0;use_filtered<=0;recovery_frames<=0;
       if(!session_valid || pending_slot!=session_slot || session_count==3) session_count<=0;
       session_valid<=1;session_slot<=pending_slot;recording<=1;learn_since<=time_ms;
       stable_count<=0;average_count<=0;sample_progress<=0;status<=4;
       product_id<=0;match_score<=0;votes<=0;vote_class<=0;bad_frames<=0;
      end
     end
     SCAN_READ: state<=SCAN_WAIT;
     SCAN_WAIT: state<=SCAN_ADD;
     SCAN_ADD: begin
      bg_distance<=background_valid ? bg_next[15:0]:16'hffff;
      temporal_distance<=previous_valid ? temporal_next[15:0]:16'hffff;
      if(dimension==127) begin
       frame_stable<=stable_now;
       use_filtered<=TEMPORAL_FILTER && !recording && filter_valid && temporal_next<=400 && mean_delta<=16;
       filter_valid<=TEMPORAL_FILTER && !recording && (!previous_valid || (temporal_next<=400 && mean_delta<=16));
       dimension<=0;previous_valid<=1;previous_mean<=snapshot_mean;result_frame_id<=snapshot_id;
       if(recording) begin
        if(session_slot<5 && learning_empty) begin
         recording<=0;sample_progress<=0;average_count<=0;stable_count<=0;
         learn_error<=1;learn_reason<=3;status<=1;state<=IDLE;
        end else if(!stable_now) begin stable_count<=0;average_count<=0;sample_progress<=0;state<=IDLE;end
        else if(stable_count<3) begin stable_count<=stable_count+1'b1;state<=IDLE;end
        else state<=AVG_READ;
       end else if(!background_valid) begin product_id<=0;status<=6;match_score<=0;state<=IDLE;end
       else begin class_index<=0;view_index<=0;distance<=0;state<=SCORE_READ;end
      end else begin dimension<=dimension+1'b1;state<=SCAN_READ;end
     end
     AVG_READ: state<=AVG_WAIT;
     AVG_WAIT: state<=AVG_ADD;
     AVG_ADD: if(dimension==127) begin
      dimension<=0;average_count<=average_count+1'b1;sample_progress<=average_count+1'b1;
      edge_average_sum<=average_count==0 ? {3'd0,snapshot_edges}:edge_average_sum+snapshot_edges;
      state<=LABEL_ENABLE && session_slot<5 ? 20:(average_count==7 ? SAVE_READ:IDLE);
     end else begin dimension<=dimension+1'b1;state<=AVG_READ;end
     20:state<=21;
     21:if(label_done)begin
      if(average_count==8 && label_quality!=0)begin
       recording<=0;learn_error<=1;learn_reason<=label_quality==1 ? 6:label_quality==2 ? 7:3;
       sample_progress<=0;status<=0;state<=IDLE;
      end else state<=average_count==8 ? SAVE_READ:IDLE;
     end
     SAVE_READ: state<=SAVE_WAIT;
     SAVE_WAIT: state<=SAVE_WRITE;
     SAVE_WRITE: if(dimension==127) begin
      dimension<=0;learn_error<=0;learn_reason<=0;
      if(session_slot==5) begin
       record_counter<=record_counter+1'b1;record_slot<=5;record_view<=0;
       background_valid<=1;background_bank<=!background_bank;background_edges<=rounded_edge_average[14:3];
       recording<=0;session_count<=0;session_valid<=0;previous_valid<=0;
       product_id<=0;match_score<=0;votes<=0;vote_class<=0;bad_frames<=0;empty_frames<=0;
       status<=learned_classes==0 ? 3'd7:3'd0;state<=IDLE;
      end else if(session_count==2) begin commit_view<=0;state<=COMMIT_READ;end
      else begin
       record_counter<=record_counter+1'b1;record_slot<=session_slot;record_view<=session_count;
       session_count<=session_count+1'b1;recording<=0;status<=0;state<=IDLE;
      end
     end else begin dimension<=dimension+1'b1;state<=SAVE_READ;end
     COMMIT_READ: state<=COMMIT_WAIT;
     COMMIT_WAIT: state<=COMMIT_WRITE;
     COMMIT_WRITE: if(dimension==127) begin
      dimension<=0;
      if(commit_view==2) begin
       active_banks[session_slot]<=!active_banks[session_slot];
       learned_classes[session_slot]<=1;sample_counts[session_slot*2+:2]<=3;
       record_counter<=record_counter+1'b1;record_slot<=session_slot;record_view<=2;
       session_count<=3;recording<=0;status<=0;state<=IDLE;
      end else begin commit_view<=commit_view+1'b1;state<=COMMIT_READ;end
     end else begin dimension<=dimension+1'b1;state<=COMMIT_READ;end
     SCORE_READ: if(!learned_classes[class_index]) begin
      dimension<=0;view_index<=0;distance<=0;
      if(class_index==4) state<=RANK_INIT;
      else class_index<=class_index+1'b1;
     end else state<=SCORE_WAIT;
     SCORE_WAIT: state<=SCORE_ADD;
     SCORE_ADD: begin
      distance<=distance_next[15:0];
      if(dimension==127) begin
       view_distances[(class_index*3+view_index)*16+:16]<=distance_next[15:0];
       if(distance_next<class_distance[class_index]) class_distance[class_index]<=distance_next[15:0];
       dimension<=0;distance<=0;
       if(view_index==2) begin
        view_index<=0;
        if(class_index==4) state<=RANK_INIT;
        else begin class_index<=class_index+1'b1;state<=SCORE_READ;end
       end else begin view_index<=view_index+1'b1;state<=SCORE_READ;end
      end else begin dimension<=dimension+1'b1;state<=SCORE_READ;end
     end
     // timing closure: one class comparison per cycle, preserving the
     // original ascending-class tie break. Keep ranking out of score/hysteresis
     // arithmetic; six clocks are negligible beside a complete capture frame.
     RANK_INIT: begin
      best<=16'hffff;second<=16'hffff;incumbent<=16'hffff;best_class<=0;rank_index<=0;
      state<=LABEL_ENABLE ? 19:RANK;
     end
     19:if(label_done)begin
      for(i=0;i<5;i=i+1)class_distance[i]<=label_distances[i*16+:16];
      state<=RANK;
     end
     RANK: begin
      if(learned_classes[rank_index])begin
       if(class_distance[rank_index]<best)begin
        second<=best;best<=class_distance[rank_index];best_class<=rank_index+1'b1;
       end else if(class_distance[rank_index]<second)second<=class_distance[rank_index];
       if(confirmed_class==rank_index+1'b1)incumbent<=class_distance[rank_index];
      end
      if(rank_index==4)state<=FINAL;
      else rank_index<=rank_index+1'b1;
     end
     FINAL: begin
      state<=IDLE;
      if(empty_evidence) begin
       votes<=0;vote_class<=0;
       if(empty_frames<2) empty_frames<=empty_frames+1'b1;
       if(empty_frames>=1) begin
        if(MANUAL_IDENTIFY && identify_busy)begin identify_busy<=0;identify_done<=1;identify_reason<=7;end
        product_id<=0;confirmed_class<=0;status<=1;match_score<=0;bad_frames<=0;recovery_frames<=0;filter_valid<=0;use_filtered<=0;end
      end else begin
       empty_frames<=0;
       if(learned_classes==0) begin product_id<=0;status<=7;match_score<=0;votes<=0;vote_class<=0;end
       else if(MANUAL_IDENTIFY)begin
        if(identify_busy && identify_elapsed<2000)begin
         if(label_quality!=0)begin identify_reason<=label_quality;identify_stable<=0;end
         else if(!frame_stable)begin identify_stable<=0;identify_reason<=5;end
         else if(identify_stable<3)identify_stable<=identify_stable+1'b1;
         else begin
          identify_frames<=identify_frames+1'b1;identify_reason<=0;
          if(initial_good)begin
           identify_votes[best_class-1]<=identify_votes[best_class-1]+1'b1;
           if(identify_votes[best_class-1]+1'b1>identify_max)begin
            identify_max<=identify_votes[best_class-1]+1'b1;identify_winner<=best_class;identify_score<=score_of(best);
           end
          end
          if(identify_frames==7)begin
           identify_busy<=0;identify_done<=1;
           if(initial_good && identify_votes[best_class-1]>=5)begin
            product_id<=best_class;confirmed_class<=best_class;status<=3;match_score<=score_of(best);
            if(confirmed_class!=best_class)confirm_pulse<=1;
           end else if(identify_max>=6)begin
            product_id<=identify_winner;confirmed_class<=identify_winner;status<=3;match_score<=identify_score;
            if(confirmed_class!=identify_winner)confirm_pulse<=1;
           end else begin product_id<=0;status<=2;match_score<=0;identify_reason<=6;end
          end
         end
        end
       end
       else if(confirmed_class==0) begin
       if(initial_good) begin
        status<=0;match_score<=0;
        if(vote_class!=best_class) begin vote_class<=best_class;votes<=1;candidate_since<=time_ms;end
        else begin
         if(votes<15) votes<=votes+1'b1;
         if(votes>=CONFIRM_FRAMES-1 && candidate_elapsed>=CONFIRM_MS) begin
          product_id<=best_class;confirmed_class<=best_class;status<=3;match_score<=score_of(best);bad_frames<=0;vote_class<=0;votes<=0;confirm_pulse<=1;
         end
        end
       end else begin status<=2;vote_class<=0;votes<=0;match_score<=0;end
      end else begin
       if(product_id!=0)begin status<=3;match_score<=score_sum[8:2];end
       if(hold_good)begin
        bad_frames<=0;
        if(product_id!=0 || recovery_frames>=2)begin
         product_id<=confirmed_class;status<=3;
         match_score<=product_id!=0 ? score_sum[8:2]:score_of(incumbent);recovery_frames<=0;
        end else begin recovery_frames<=recovery_frames+1'b1;status<=2;match_score<=0;end
       end else begin
        recovery_frames<=0;
        if(bad_frames==0)loss_since<=time_ms;
        if(bad_frames<15)bad_frames<=bad_frames+1'b1;
        if(bad_frames>=9 && loss_elapsed>=LOSS_MS)begin product_id<=0;status<=2;match_score<=0;end
       end
       if(switch_good) begin
        if(vote_class!=best_class) begin vote_class<=best_class;votes<=1;candidate_since<=time_ms;end
        else begin
         if(votes<15) votes<=votes+1'b1;
         if(votes>=SWITCH_FRAMES-1 && candidate_elapsed>=SWITCH_MS) begin
          product_id<=best_class;confirmed_class<=best_class;status<=3;match_score<=score_of(best);bad_frames<=0;vote_class<=0;votes<=0;confirm_pulse<=1;
         end
        end
       end else begin vote_class<=0;votes<=0;end
      end
      end
     end
     default:state<=IDLE;
    endcase
   end
  end
 end
endmodule
