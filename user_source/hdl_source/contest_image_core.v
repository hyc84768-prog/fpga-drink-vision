// Four-clock drink/red latency; algorithm display adds four isolated clocks.
// HDMI sync and logos carry the selected matching delay.
// three groups, four keys, camera-learning through aligned RGB smoothing.
module contest_image_core #(
    parameter integer WIDTH=1280, HEIGHT=720, DEBOUNCE=750000, LONG_PRESS=75000000,
    parameter [7:0] RED_MIN=48, RED_MARGIN=12,
    parameter integer MIN_RED_SAMPLES=24, MIN_RED_RUN=4, RED_HUE_SCALE=6,
    parameter integer ACQUIRE_FRAMES=2, LOST_FRAMES=6,
    parameter integer MOTION_THRESHOLD=20, MOTION_MIN_POINTS=3, MOTION_HOLD_FRAMES=12
)(
    input wire clk, rst_n, frame_start, de,
    input wire [11:0] x,y,
    input wire [23:0] rgb,
    input wire [3:0] keys_n,dip_switches,
    input wire ae_active, awb_active, awb_locked, calibration_changed,ae_hold_active,
    input wire [7:0] frame_age,
    input wire frame_age_valid,
    input wire [31:0] capture_id,
    input wire capture_valid,
    output reg [23:0] pixel,
    output reg [3:0] mode,
    output reg target_valid,
    output reg [11:0] target_x,target_y,
    output reg motion,alert,
    output wire algorithm_active,
    output wire calibration_request,exposure_hold_request,
    output reg [63:0] board_status
);
    wire [7:0] r=rgb[23:16], g=rgb[15:8], b=rgb[7:0];
    wire [9:0] luma_sum={2'b0,r}+{1'b0,g,1'b0}+{2'b0,b};
    wire [7:0] luma=luma_sum[9:2];
    wire [8:0] gb_delta=g>=b ? g-b : b-g;
    wire [10:0] red_four={1'b0,r,2'b00};
    wire [10:0] green_seven={g,3'b000}-{3'b0,g};
    wire [10:0] blue_seven={b,3'b000}-{3'b0,b};
    wire [7:0] min_gb=g<b ? g:b;
    // Hue distance normalized by chroma: scale 6 admits about +/-10 degrees
    // around red, rather than accepting orange on an absolute margin alone.
    wire [12:0] hue_distance=gb_delta*RED_HUE_SCALE;
    wire red_hit=r>=RED_MIN && {1'b0,r}>{1'b0,g}+RED_MARGIN &&
        {1'b0,r}>{1'b0,b}+RED_MARGIN && red_four>=green_seven &&
        red_four>=blue_seven && hue_distance<=({5'd0,r}-{5'd0,min_gb});

    wire [1:0] group_id,effect_level;
    assign algorithm_active=group_id==2;
    wire [2:0] ui_page,menu_item,selected_class,effect_mode,selected_learn_slot;
    wire [3:0] switch_flags;
    wire identify_request;
    wire learn_pulse,learn_cancel,change_mode,write_blocked,cal_timeout;
    wire demo_mode=group_id==1;
    wire [4:0] bottle_enabled;
    wire bottle_recording;
    reg [19:0] red_count;
    contest_ui_control #(.DEBOUNCE(DEBOUNCE)) u_ui(
        .clk(clk),.rst_n(rst_n),.frame_start(frame_start),.key_n(keys_n),.switches(dip_switches),
        .recording(bottle_recording),.library_present(|bottle_enabled),.calibration_changed(calibration_changed),
        .group_id(group_id),.page(ui_page),.menu_item(menu_item),.selected_class(selected_class),
        .effect_mode(effect_mode),.effect_level(effect_level),.switches_filtered(switch_flags),.learn_slot(selected_learn_slot),
        .identify_request(identify_request),.learn_request(learn_pulse),.learn_cancel(learn_cancel),.calibration_request(calibration_request),
        .group_changed(change_mode),.write_blocked(write_blocked),.cal_timeout(cal_timeout));
    // switches use enable semantics, 1=AUTO / 1=WRITE allowed.
    assign exposure_hold_request=~switch_flags[2];
    always @(*) begin
        if(group_id==1) mode=6;
        else if(group_id==2) mode={1'b0,effect_mode};
        else if(ui_page==6) mode=13;
        else if(ui_page==3) mode=7+selected_class;
        else if(ui_page==4) mode=12;
        else mode=0;
    end
    reg [11:0] min_x,max_x,min_y,max_y,box_min_x,box_max_x,box_min_y,box_max_y;
    reg [8:0] run_count;
    reg [11:0] run_x,run_end_x,run_y,acquire_x,acquire_y;
    reg [3:0] acquire_count,lost_frames;
    reg tracking_live;
    reg [5:0] alert_hold;
    wire roi_hit=!target_valid ||
        ({1'b0,x}+13'd128>={1'b0,box_min_x} && {1'b0,x}<={1'b0,box_max_x}+13'd128 &&
         {1'b0,y}+13'd128>={1'b0,box_min_y} && {1'b0,y}<={1'b0,box_max_y}+13'd128);
    wire red_sample=demo_mode && de && x[1:0]==0 && y[1:0]==0;
    wire [11:0] candidate_x=({1'b0,min_x}+{1'b0,max_x})>>1;
    wire [11:0] candidate_y=({1'b0,min_y}+{1'b0,max_y})>>1;
    wire candidate_ok=red_count>=MIN_RED_SAMPLES && max_x>=min_x+12'd12 && max_y>=min_y+12'd8;
    wire candidate_near={1'b0,candidate_x}+13'd96>={1'b0,acquire_x} &&
        {1'b0,candidate_x}<={1'b0,acquire_x}+13'd96 &&
        {1'b0,candidate_y}+13'd96>={1'b0,acquire_y} &&
        {1'b0,candidate_y}<={1'b0,acquire_y}+13'd96;
    function [11:0] smooth;
        input [11:0] old_value,new_value;
        reg [13:0] total;
        begin
            total={2'b0,old_value}+{1'b0,old_value,1'b0}+{2'b0,new_value}+14'd2;
            smooth=total[13:2];
        end
    endfunction
    // Reject isolated pixels before accumulating the box; lock adds ROI + IIR.
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            min_x<=WIDTH-1; max_x<=0; min_y<=HEIGHT-1; max_y<=0;
            red_count<=0; run_count<=0; run_x<=0; run_end_x<=0; run_y<=0;
            box_min_x<=0; box_max_x<=0; box_min_y<=0; box_max_y<=0;
            acquire_count<=0; acquire_x<=0; acquire_y<=0; lost_frames<=0;
            target_valid<=0; tracking_live<=0; target_x<=0; target_y<=0;
            alert<=0; alert_hold<=0;
        end else begin
            if(!demo_mode || change_mode) begin
                min_x<=WIDTH-1;max_x<=0;min_y<=HEIGHT-1;max_y<=0;
                red_count<=0;run_count<=0;acquire_count<=0;lost_frames<=0;
                target_valid<=0;tracking_live<=0;target_x<=0;target_y<=0;
                box_min_x<=0;box_max_x<=0;box_min_y<=0;box_max_y<=0;
                alert<=0;alert_hold<=0;
            end else if(frame_start) begin
                min_x<=WIDTH-1; max_x<=0; min_y<=HEIGHT-1; max_y<=0;
                red_count<=0; run_count<=0;
                if(candidate_ok) begin
                    acquire_x<=candidate_x; acquire_y<=candidate_y; lost_frames<=0;
                    if(target_valid || ACQUIRE_FRAMES==1 || (candidate_near && acquire_count>=ACQUIRE_FRAMES-1)) begin
                        target_valid<=1; tracking_live<=1; acquire_count<=0;
                        if(target_valid) begin
                            box_min_x<=smooth(box_min_x,min_x); box_max_x<=smooth(box_max_x,max_x);
                            box_min_y<=smooth(box_min_y,min_y); box_max_y<=smooth(box_max_y,max_y);
                            target_x<=smooth(target_x,candidate_x); target_y<=smooth(target_y,candidate_y);
                        end else begin
                            box_min_x<=min_x; box_max_x<=max_x; box_min_y<=min_y; box_max_y<=max_y;
                            target_x<=candidate_x; target_y<=candidate_y;
                        end
                    end else if(candidate_near && acquire_count!=0) acquire_count<=acquire_count+1'b1;
                    else acquire_count<=1;
                end else begin
                    acquire_count<=0; tracking_live<=0;
                    if(lost_frames>=LOST_FRAMES-1) begin
                        target_valid<=0; target_x<=0; target_y<=0; lost_frames<=0;
                        box_min_x<=0; box_max_x<=0; box_min_y<=0; box_max_y<=0;
                    end else lost_frames<=lost_frames+1'b1;
                end
                if(target_valid && tracking_live && candidate_ok && candidate_x>=400 &&
                   candidate_x<=880 && candidate_y>=220 && candidate_y<=500) begin
                    alert<=1; alert_hold<=60;
                end else if(alert_hold!=0) alert_hold<=alert_hold-1'b1;
                else alert<=0;
            end else begin
                if((!de || (red_sample && (!red_hit || !roi_hit || x==0))) && run_count!=0) begin
                    if(run_count>=MIN_RED_RUN) begin
                        if(run_x<min_x) min_x<=run_x;
                        if(run_end_x>max_x) max_x<=run_end_x;
                        if(run_y<min_y) min_y<=run_y;
                        if(run_y>max_y) max_y<=run_y;
                        red_count<=red_count+run_count;
                    end
                    run_count<=0;
                end
                if(red_sample && red_hit && roi_hit) begin
                    if(run_count==0 || x==0) begin run_x<=x; run_y<=y; run_count<=1; end
                    else if(run_count!=9'h1ff) run_count<=run_count+1'b1;
                    run_end_x<=x;
                end
            end
        end
    end

    // Synchronous read-before-write grid history, padded stride 64. First
    // incomplete frame is excluded; no reset tree or mux on the RAM data.
    reg [7:0] previous_luma [0:2047];
    wire sample_point=demo_mode && de && x<WIDTH && y<HEIGHT && x[4:0]==16 && y[4:0]==16;
    wire [10:0] sample_index={y[9:5],x[10:5]};
    reg sample_pending,previous_valid;
    reg [7:0] old_sample,new_sample;
    reg [11:0] sample_x,sample_y,samples_in_frame,motion_count;
    reg [4:0] motion_hold;
    reg [15:0] motion_events;
    reg [11:0] motion_min_x,motion_max_x,motion_min_y,motion_max_y;
    reg [11:0] motion_box_x0,motion_box_x1,motion_box_y0,motion_box_y1;
    wire [8:0] sample_delta=new_sample>=old_sample ? new_sample-old_sample : old_sample-new_sample;
    localparam GRID_POINTS=((WIDTH+15)/32)*((HEIGHT+15)/32);
    always @(posedge clk) begin
        if(sample_point) begin
            old_sample<=previous_luma[sample_index]; previous_luma[sample_index]<=luma;
            new_sample<=luma; sample_x<=x; sample_y<=y;
        end
    end
    function [15:0] bcd_inc;
        input [15:0] value;
        begin
            bcd_inc=value;
            if(value!=16'h9999) begin
                if(value[3:0]!=9) bcd_inc=value+1'b1;
                else if(value[7:4]!=9) bcd_inc={value[15:4]+12'd1,4'd0};
                else if(value[11:8]!=9) bcd_inc={value[15:8]+8'd1,8'd0};
                else bcd_inc={value[15:12]+4'd1,12'd0};
            end
        end
    endfunction
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            sample_pending<=0; previous_valid<=0; samples_in_frame<=0;
            motion_count<=0; motion<=0; motion_hold<=0; motion_events<=0;
            motion_min_x<=WIDTH-1; motion_max_x<=0; motion_min_y<=HEIGHT-1; motion_max_y<=0;
            motion_box_x0<=0; motion_box_x1<=0; motion_box_y0<=0; motion_box_y1<=0;
        end else begin
            sample_pending<=sample_point;
            if(!demo_mode || change_mode) begin
                sample_pending<=0;previous_valid<=0;samples_in_frame<=0;
                motion_count<=0;motion<=0;motion_hold<=0;motion_events<=0;
                motion_min_x<=WIDTH-1;motion_max_x<=0;motion_min_y<=HEIGHT-1;motion_max_y<=0;
                motion_box_x0<=0;motion_box_x1<=0;motion_box_y0<=0;motion_box_y1<=0;
            end else if(frame_start) begin
                previous_valid<=(samples_in_frame==GRID_POINTS);
                samples_in_frame<=0; motion_count<=0;
                motion_min_x<=WIDTH-1; motion_max_x<=0; motion_min_y<=HEIGHT-1; motion_max_y<=0;
                if(previous_valid && motion_count>=MOTION_MIN_POINTS) begin
                    motion<=1; motion_hold<=MOTION_HOLD_FRAMES;
                    if(!motion) motion_events<=bcd_inc(motion_events);
                    motion_box_x0<=motion_min_x-12'd16; motion_box_y0<=motion_min_y-12'd16;
                    motion_box_x1<=motion_max_x+12'd15<WIDTH ? motion_max_x+12'd15 : WIDTH-1;
                    motion_box_y1<=motion_max_y+12'd15<HEIGHT ? motion_max_y+12'd15 : HEIGHT-1;
                end else if(motion_hold!=0) motion_hold<=motion_hold-1'b1;
                else motion<=0;
            end else if(sample_pending) begin
                samples_in_frame<=samples_in_frame+1'b1;
                if(previous_valid && sample_delta>=MOTION_THRESHOLD) begin
                    motion_count<=motion_count+1'b1;
                    if(sample_x<motion_min_x) motion_min_x<=sample_x;
                    if(sample_x>motion_max_x) motion_max_x<=sample_x;
                    if(sample_y<motion_min_y) motion_min_y<=sample_y;
                    if(sample_y>motion_max_y) motion_max_y<=sample_y;
                end
            end
        end
    end

    wire [23:0] rgb_d,cartoon_d,smoothed_d;
    wire de_d;
    wire [11:0] x_d,y_d;
    wire [7:0] luma_d,median_d,sobel_d,equalized_d;
    wire histogram_ready;
    reg [23:0] effect;
    contest_spatial_filters #(.WIDTH(WIDTH)) u_spatial(
        .clk(clk),.rst_n(rst_n),.de(de),.x(x),.y(y),.rgb(rgb),
        .out_de(de_d),.out_x(x_d),.out_y(y_d),.original(rgb_d),.cartoon(cartoon_d),
        .gray(luma_d),.median(median_d),.sobel(sobel_d),.smoothed(smoothed_d));
    contest_histogram_equalizer #(.WIDTH(WIDTH),.HEIGHT(HEIGHT)) u_equalizer(
        .clk(clk),.rst_n(rst_n),.frame_start(frame_start),.de(de),.x(x),.y(y),
        .luma(luma),.equalized(equalized_d),.map_valid(histogram_ready));
    wire [2:0] bottle_id,bottle_status;
    wire [6:0] bottle_score;
    wire [4:0] bottle_learned;
    wire bottle_learn_error;
    wire [31:0] bottle_result_frame;
    wire [7:0] bottle_record_counter;
    wire [2:0] bottle_record_slot;
    wire [1:0] bottle_record_view;
    wire [9:0] bottle_sample_counts;
    wire [1:0] bottle_session_count;
    wire [3:0] bottle_sample_progress;
    wire [2:0] bottle_learn_reason;
    wire background_ready,bottle_confirm;
    wire [15:0] bottle_bg_distance,bottle_best_distance,bottle_hold_distance;
    wire [11:0] bottle_edges;
    wire [7:0] bottle_reference;
    reg [3:0] capture_valid_pipe,frame_start_pipe,calibration_pipe;
    reg [31:0] capture_pipe[0:3];
    integer meta_i;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            capture_valid_pipe<=0;frame_start_pipe<=0;calibration_pipe<=0;
            for(meta_i=0;meta_i<4;meta_i=meta_i+1)capture_pipe[meta_i]<=0;
        end else begin
            capture_valid_pipe<={capture_valid_pipe[2:0],capture_valid};
            frame_start_pipe<={frame_start_pipe[2:0],frame_start};
            calibration_pipe<={calibration_pipe[2:0],calibration_changed};
            capture_pipe[0]<=capture_id;for(meta_i=1;meta_i<4;meta_i=meta_i+1)capture_pipe[meta_i]<=capture_pipe[meta_i-1];
        end
    end
    // Additional display processing never feeds back into the classifier.
    wire fx_de;wire [11:0] fx_x,fx_y;wire [71:0] fx_payload;
    wire [7:0] clean_edges,adaptive_binary,display_mean;
    contest_display_enhance #(.WIDTH(WIDTH),.HEIGHT(HEIGHT)) u_display_enhance(
        .clk(clk),.rst_n(rst_n),.frame_start(frame_start_pipe[3]),
        .de(de_d),.x(x_d),.y(y_d),.median_in(median_d),
        .payload({rgb_d,cartoon_d,luma_d,median_d,equalized_d}),.level(effect_level),
        .out_de(fx_de),.out_x(fx_x),.out_y(fx_y),.out_payload(fx_payload),
        .edge_out(clean_edges),.binary_out(adaptive_binary),.mean_luma(display_mean));
    wire view_de=algorithm_active ? fx_de:de_d;
    wire [11:0] view_x=algorithm_active ? fx_x:x_d,view_y=algorithm_active ? fx_y:y_d;
    wire [23:0] view_rgb=algorithm_active ? fx_payload[71:48]:rgb_d;
    wire [23:0] view_cartoon=fx_payload[47:24];
    wire [7:0] view_gray=fx_payload[23:16],view_median=fx_payload[15:8],view_equalized=fx_payload[7:0];
    wire identify_busy,identify_done;wire [2:0] identify_reason;wire [15:0] bottle_structure,bottle_color,bottle_margin;
    contest_bottle_classifier #(.LABEL_ENABLE(1),.MANUAL_IDENTIFY(1)) u_bottle(
        .clk(clk),.rst_n(rst_n),.frame_start(frame_start_pipe[3]),.de(de_d),.x(x_d),.y(y_d),.rgb(smoothed_d),
        .capture_id(capture_pipe[3]),.capture_valid(capture_valid_pipe[3]),.calibration_ok(awb_locked),
        .learn_request(learn_pulse),.learn_slot(selected_learn_slot[2:0]),.product_id(bottle_id),.status(bottle_status),
        .match_score(bottle_score),.learned_classes(bottle_learned),.enabled_classes(bottle_enabled),
        .learn_error(bottle_learn_error),.result_frame_id(bottle_result_frame),
        .record_counter(bottle_record_counter),.record_slot(bottle_record_slot),.record_view(bottle_record_view),
        .learn_cancel(learn_cancel),.calibration_changed(calibration_pipe[3]),
        .sample_counts(bottle_sample_counts),.session_count(bottle_session_count),
        .sample_progress(bottle_sample_progress),.learn_reason(bottle_learn_reason),.recording(bottle_recording),
        .edge_strength(sobel_d),.background_ready(background_ready),.confirm_pulse(bottle_confirm),
        .identify_request(identify_request),.identify_cancel(group_id!=0 || ui_page!=0),
        .identify_busy(identify_busy),.identify_done(identify_done),.identify_reason(identify_reason),
        .debug_structure(bottle_structure),.debug_color(bottle_color),.debug_margin(bottle_margin),.debug_background(bottle_bg_distance),.debug_best(bottle_best_distance),
        .debug_incumbent(bottle_hold_distance),.debug_edges(bottle_edges),.debug_reference(bottle_reference));

    reg [15:0] x_digits,y_digits,x_work,y_work;
    reg [15:0] motion_x_digits,motion_y_digits,motion_x_work,motion_y_work;
    reg [11:0] motion_x_shift,motion_y_shift;
    wire [12:0] motion_x_sum={1'b0,motion_box_x0}+{1'b0,motion_box_x1};
    wire [12:0] motion_y_sum={1'b0,motion_box_y0}+{1'b0,motion_box_y1};
    reg [11:0] age_digits,x_shift,y_shift,age_shift,age_work;
    reg age_digits_valid,age_pending,coord_latch_pending;
    reg [3:0] bcd_count;
    reg [23:0] display_frames;
    // Center 32x32 patch RGB from the FPGA data, independent of monitor/phone
    // color settings. Exact sample count prevents displaying partial frames.
    reg [17:0] center_r,center_g,center_b;
    reg [10:0] center_count;
    reg [23:0] center_rgb;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin center_r<=0; center_g<=0; center_b<=0; center_count<=0; center_rgb<=0; end
        else if(frame_start) begin
            if(center_count==1024) center_rgb<={center_r[17:10],center_g[17:10],center_b[17:10]};
            center_r<=0; center_g<=0; center_b<=0; center_count<=0;
        end else if(de && x>=WIDTH/2-16 && x<WIDTH/2+16 && y>=HEIGHT/2-16 && y<HEIGHT/2+16) begin
            center_r<=center_r+r; center_g<=center_g+g; center_b<=center_b+b; center_count<=center_count+1'b1;
        end
    end
    function [15:0] bcd_step;
        input [15:0] value;
        input next_bit;
        reg [15:0] adjusted;
        integer n;
        begin
            adjusted=value;
            for(n=0;n<4;n=n+1) if(adjusted[n*4+:4]>=5) adjusted[n*4+:4]=adjusted[n*4+:4]+4'd3;
            bcd_step={adjusted[14:0],next_bit};
        end
    endfunction
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            motion_x_digits<=0;motion_y_digits<=0;motion_x_work<=0;motion_y_work<=0;motion_x_shift<=0;motion_y_shift<=0;
            x_digits<=0; y_digits<=0; age_digits<=0; age_digits_valid<=0;
            x_shift<=0; y_shift<=0; age_shift<=0; x_work<=0; y_work<=0; age_work<=0;
            bcd_count<=0; age_pending<=0; display_frames<=0; coord_latch_pending<=0;
        end else begin
            coord_latch_pending<=frame_start;
            if(frame_start) begin
            if(display_frames[15:0]==16'h9999) begin
                display_frames[15:0]<=0;
                display_frames[23:16]<=display_frames[23:16]==8'h99 ? 8'd0 : bcd_inc({8'd0,display_frames[23:16]});
            end else display_frames[15:0]<=bcd_inc(display_frames[15:0]);
            end
            // Wait one blanking clock for this frame's tracking update, so
            // coordinates correspond to the visible box in the current frame.
            if(coord_latch_pending) begin
            x_shift<=target_valid ? target_x : 12'd0; y_shift<=target_valid ? target_y : 12'd0;
            motion_x_shift<=motion ? motion_x_sum[12:1]:12'd0;motion_y_shift<=motion ? motion_y_sum[12:1]:12'd0;
            motion_x_work<=0;motion_y_work<=0;
            age_shift<={4'd0,frame_age}; x_work<=0; y_work<=0; age_work<=0;
            bcd_count<=12; age_pending<=frame_age_valid;
        end else if(bcd_count!=0) begin
            motion_x_work<=bcd_step(motion_x_work,motion_x_shift[11]);motion_y_work<=bcd_step(motion_y_work,motion_y_shift[11]);
            motion_x_shift<=motion_x_shift<<1;motion_y_shift<=motion_y_shift<<1;
            x_work<=bcd_step(x_work,x_shift[11]); y_work<=bcd_step(y_work,y_shift[11]);
            age_work<=bcd_step({4'd0,age_work},age_shift[11]);
            x_shift<={x_shift[10:0],1'b0}; y_shift<={y_shift[10:0],1'b0}; age_shift<={age_shift[10:0],1'b0};
            bcd_count<=bcd_count-1'b1;
            if(bcd_count==1) begin
                motion_x_digits<=bcd_step(motion_x_work,motion_x_shift[11]);motion_y_digits<=bcd_step(motion_y_work,motion_y_shift[11]);
                x_digits<=bcd_step(x_work,x_shift[11]); y_digits<=bcd_step(y_work,y_shift[11]);
                age_digits<=bcd_step({4'd0,age_work},age_shift[11]); age_digits_valid<=age_pending;
            end
            end
        end
    end

    // 5x7 font, 2x scale; 16-pixel character/row pitch uses only bit slices.
    function [4:0] font;
        input [7:0] ch;
        input [2:0] row;
        reg [34:0] bits;
        begin
            case(ch)
                "A":bits=35'b01110_10001_10001_11111_10001_10001_10001;
                "B":bits=35'b11110_10001_10001_11110_10001_10001_11110;
                "C":bits=35'b01110_10001_10000_10000_10000_10001_01110;
                "D":bits=35'b11110_10001_10001_10001_10001_10001_11110;
                "E":bits=35'b11111_10000_10000_11110_10000_10000_11111;
                "F":bits=35'b11111_10000_10000_11110_10000_10000_10000;
                "G":bits=35'b01110_10001_10000_10111_10001_10001_01110;
                "H":bits=35'b10001_10001_10001_11111_10001_10001_10001;
                "I":bits=35'b01110_00100_00100_00100_00100_00100_01110;
                "K":bits=35'b10001_10010_10100_11000_10100_10010_10001;
                "L":bits=35'b10000_10000_10000_10000_10000_10000_11111;
                "M":bits=35'b10001_11011_10101_10101_10001_10001_10001;
                "N":bits=35'b10001_11001_10101_10011_10001_10001_10001;
                "O":bits=35'b01110_10001_10001_10001_10001_10001_01110;
                "P":bits=35'b11110_10001_10001_11110_10000_10000_10000;
                "Q":bits=35'b01110_10001_10001_10001_10101_10010_01101;
                "R":bits=35'b11110_10001_10001_11110_10100_10010_10001;
                "S":bits=35'b01111_10000_10000_01110_00001_00001_11110;
                "T":bits=35'b11111_00100_00100_00100_00100_00100_00100;
                "U":bits=35'b10001_10001_10001_10001_10001_10001_01110;
                "V":bits=35'b10001_10001_10001_10001_10001_01010_00100;
                "W":bits=35'b10001_10001_10001_10101_10101_10101_01010;
                "X":bits=35'b10001_10001_01010_00100_01010_10001_10001;
                "Y":bits=35'b10001_10001_01010_00100_00100_00100_00100;
                "0":bits=35'b01110_10001_10011_10101_11001_10001_01110;
                "1":bits=35'b00100_01100_00100_00100_00100_00100_01110;
                "2":bits=35'b01110_10001_00001_00010_00100_01000_11111;
                "3":bits=35'b11110_00001_00001_01110_00001_00001_11110;
                "4":bits=35'b00010_00110_01010_10010_11111_00010_00010;
                "5":bits=35'b11111_10000_10000_11110_00001_00001_11110;
                "6":bits=35'b01110_10000_10000_11110_10001_10001_01110;
                "7":bits=35'b11111_00001_00010_00100_01000_01000_01000;
                "8":bits=35'b01110_10001_10001_01110_10001_10001_01110;
                "9":bits=35'b01110_10001_10001_01111_00001_00001_01110;
                "/":bits=35'b00001_00001_00010_00100_01000_10000_10000;
                ":":bits=35'b00000_00100_00100_00000_00100_00100_00000;
                default:bits=0;
            endcase
            font=row<7 ? (bits >> ((6-row)*5)) : 5'd0;
        end
    endfunction
    function [7:0] mode_char;
        input [3:0] m;
        input [3:0] col;
        reg [63:0] label;
        begin
            case(m)
                0:label="ORIGINAL"; 1:label="GRAY    "; 2:label="SOBEL   ";3:label="CARTOON ";
                4:label="MEDIAN  ";5:label="CLHE    ";6:label="BINARY  ";
                7:label="LEARN 1 ";8:label="LEARN 2 ";9:label="LEARN 3 ";
                10:label="LEARN 4 ";11:label="LEARN 5 ";12:label="BACKGRND";default:label="DIAGNOSE";
            endcase
            mode_char=label >> ((7-col)*8);
        end
    endfunction
    // CHINESE_FONT_BEGIN
    function [7:0] cn_phrase_char;
        input [5:0] phrase; input [3:0] slot;
        begin case({phrase,slot})
            10'd0:cn_phrase_char=8'd0;
            10'd1:cn_phrase_char=8'd1;
            10'd2:cn_phrase_char=8'd2;
            10'd3:cn_phrase_char=8'd3;
            10'd16:cn_phrase_char=8'd4;
            10'd17:cn_phrase_char=8'd5;
            10'd18:cn_phrase_char=8'd6;
            10'd19:cn_phrase_char=8'd7;
            10'd20:cn_phrase_char=8'd2;
            10'd21:cn_phrase_char=8'd3;
            10'd32:cn_phrase_char=8'd8;
            10'd33:cn_phrase_char=8'd9;
            10'd34:cn_phrase_char=8'd10;
            10'd35:cn_phrase_char=8'd11;
            10'd48:cn_phrase_char=8'd12;
            10'd49:cn_phrase_char=8'd13;
            10'd50:cn_phrase_char=8'd2;
            10'd51:cn_phrase_char=8'd3;
            10'd64:cn_phrase_char=8'd14;
            10'd65:cn_phrase_char=8'd15;
            10'd66:cn_phrase_char=8'd16;
            10'd80:cn_phrase_char=8'd17;
            10'd81:cn_phrase_char=8'd18;
            10'd82:cn_phrase_char=8'd19;
            10'd83:cn_phrase_char=8'd20;
            10'd96:cn_phrase_char=8'd21;
            10'd97:cn_phrase_char=8'd22;
            10'd98:cn_phrase_char=8'd23;
            10'd99:cn_phrase_char=8'd24;
            10'd100:cn_phrase_char=8'd25;
            10'd112:cn_phrase_char=8'd26;
            10'd113:cn_phrase_char=8'd27;
            10'd128:cn_phrase_char=8'd28;
            10'd129:cn_phrase_char=8'd29;
            10'd130:cn_phrase_char=8'd30;
            10'd131:cn_phrase_char=8'd31;
            10'd144:cn_phrase_char=8'd32;
            10'd145:cn_phrase_char=8'd33;
            10'd160:cn_phrase_char=8'd34;
            10'd161:cn_phrase_char=8'd35;
            10'd162:cn_phrase_char=8'd36;
            10'd176:cn_phrase_char=8'd37;
            10'd177:cn_phrase_char=8'd38;
            10'd178:cn_phrase_char=8'd39;
            10'd179:cn_phrase_char=8'd40;
            10'd192:cn_phrase_char=8'd41;
            10'd193:cn_phrase_char=8'd42;
            10'd208:cn_phrase_char=8'd43;
            10'd209:cn_phrase_char=8'd19;
            10'd210:cn_phrase_char=8'd20;
            10'd224:cn_phrase_char=8'd44;
            10'd225:cn_phrase_char=8'd45;
            10'd226:cn_phrase_char=8'd46;
            10'd227:cn_phrase_char=8'd47;
            10'd240:cn_phrase_char=8'd48;
            10'd241:cn_phrase_char=8'd49;
            10'd242:cn_phrase_char=8'd21;
            10'd243:cn_phrase_char=8'd22;
            10'd244:cn_phrase_char=8'd23;
            10'd256:cn_phrase_char=8'd50;
            10'd257:cn_phrase_char=8'd51;
            10'd258:cn_phrase_char=8'd19;
            10'd259:cn_phrase_char=8'd17;
            10'd260:cn_phrase_char=8'd18;
            10'd272:cn_phrase_char=8'd52;
            10'd273:cn_phrase_char=8'd53;
            10'd288:cn_phrase_char=8'd43;
            10'd289:cn_phrase_char=8'd54;
            10'd304:cn_phrase_char=8'd2;
            10'd305:cn_phrase_char=8'd3;
            10'd306:cn_phrase_char=8'd55;
            10'd307:cn_phrase_char=8'd56;
            10'd320:cn_phrase_char=8'd57;
            10'd321:cn_phrase_char=8'd58;
            10'd322:cn_phrase_char=8'd59;
            10'd323:cn_phrase_char=8'd14;
            10'd336:cn_phrase_char=8'd60;
            10'd337:cn_phrase_char=8'd61;
            10'd338:cn_phrase_char=8'd62;
            10'd339:cn_phrase_char=8'd46;
            10'd352:cn_phrase_char=8'd63;
            10'd353:cn_phrase_char=8'd44;
            10'd354:cn_phrase_char=8'd25;
            10'd368:cn_phrase_char=8'd64;
            10'd369:cn_phrase_char=8'd65;
            10'd370:cn_phrase_char=8'd66;
            10'd371:cn_phrase_char=8'd67;
            10'd372:cn_phrase_char=8'd68;
            10'd373:cn_phrase_char=8'd64;
            10'd384:cn_phrase_char=8'd68;
            10'd385:cn_phrase_char=8'd64;
            10'd386:cn_phrase_char=8'd69;
            10'd387:cn_phrase_char=8'd70;
            10'd388:cn_phrase_char=8'd52;
            10'd389:cn_phrase_char=8'd14;
            10'd390:cn_phrase_char=8'd15;
            10'd400:cn_phrase_char=8'd71;
            10'd401:cn_phrase_char=8'd72;
            10'd402:cn_phrase_char=8'd73;
            10'd403:cn_phrase_char=8'd74;
            10'd404:cn_phrase_char=8'd75;
            10'd416:cn_phrase_char=8'd71;
            10'd417:cn_phrase_char=8'd76;
            10'd418:cn_phrase_char=8'd77;
            10'd419:cn_phrase_char=8'd78;
            10'd420:cn_phrase_char=8'd79;
            10'd432:cn_phrase_char=8'd57;
            10'd433:cn_phrase_char=8'd61;
            10'd448:cn_phrase_char=8'd80;
            10'd449:cn_phrase_char=8'd81;
            10'd464:cn_phrase_char=8'd82;
            10'd465:cn_phrase_char=8'd81;
            10'd480:cn_phrase_char=8'd14;
            10'd481:cn_phrase_char=8'd15;
            10'd482:cn_phrase_char=8'd83;
            10'd483:cn_phrase_char=8'd84;
            10'd484:cn_phrase_char=8'd85;
            10'd496:cn_phrase_char=8'd66;
            10'd497:cn_phrase_char=8'd67;
            10'd498:cn_phrase_char=8'd19;
            10'd499:cn_phrase_char=8'd20;
            10'd512:cn_phrase_char=8'd50;
            10'd513:cn_phrase_char=8'd86;
            10'd514:cn_phrase_char=8'd20;
            10'd515:cn_phrase_char=8'd0;
            10'd516:cn_phrase_char=8'd1;
            10'd528:cn_phrase_char=8'd71;
            10'd529:cn_phrase_char=8'd72;
            10'd530:cn_phrase_char=8'd73;
            10'd531:cn_phrase_char=8'd19;
            10'd532:cn_phrase_char=8'd87;
            10'd533:cn_phrase_char=8'd88;
            10'd534:cn_phrase_char=8'd89;
            10'd544:cn_phrase_char=8'd8;
            10'd545:cn_phrase_char=8'd9;
            10'd546:cn_phrase_char=8'd90;
            10'd547:cn_phrase_char=8'd91;
            10'd560:cn_phrase_char=8'd92;
            10'd561:cn_phrase_char=8'd93;
            10'd562:cn_phrase_char=8'd83;
            10'd563:cn_phrase_char=8'd94;
            10'd564:cn_phrase_char=8'd47;
            10'd576:cn_phrase_char=8'd95;
            10'd577:cn_phrase_char=8'd6;
            10'd578:cn_phrase_char=8'd96;
            10'd579:cn_phrase_char=8'd97;
            10'd592:cn_phrase_char=8'd96;
            10'd593:cn_phrase_char=8'd97;
            10'd594:cn_phrase_char=8'd83;
            10'd595:cn_phrase_char=8'd44;
            10'd596:cn_phrase_char=8'd45;
            10'd608:cn_phrase_char=8'd90;
            10'd609:cn_phrase_char=8'd91;
            10'd610:cn_phrase_char=8'd98;
            10'd624:cn_phrase_char=8'd99;
            10'd625:cn_phrase_char=8'd39;
            10'd626:cn_phrase_char=8'd100;
            10'd627:cn_phrase_char=8'd14;
            10'd628:cn_phrase_char=8'd15;
            10'd640:cn_phrase_char=8'd83;
            10'd641:cn_phrase_char=8'd101;
            10'd642:cn_phrase_char=8'd55;
            10'd656:cn_phrase_char=8'd102;
            10'd657:cn_phrase_char=8'd103;
            10'd672:cn_phrase_char=8'd21;
            10'd673:cn_phrase_char=8'd104;
            10'd674:cn_phrase_char=8'd105;
            10'd675:cn_phrase_char=8'd106;
            10'd676:cn_phrase_char=8'd98;
            10'd677:cn_phrase_char=8'd107;
            10'd688:cn_phrase_char=8'd50;
            10'd689:cn_phrase_char=8'd66;
            10'd690:cn_phrase_char=8'd108;
            10'd704:cn_phrase_char=8'd57;
            10'd705:cn_phrase_char=8'd58;
            10'd706:cn_phrase_char=8'd21;
            10'd707:cn_phrase_char=8'd22;
            10'd708:cn_phrase_char=8'd23;
            10'd720:cn_phrase_char=8'd19;
            10'd721:cn_phrase_char=8'd20;
            10'd722:cn_phrase_char=8'd78;
            10'd723:cn_phrase_char=8'd79;
            10'd736:cn_phrase_char=8'd63;
            10'd737:cn_phrase_char=8'd44;
            10'd738:cn_phrase_char=8'd25;
            10'd739:cn_phrase_char=8'd83;
            10'd740:cn_phrase_char=8'd109;
            10'd741:cn_phrase_char=8'd110;
            10'd752:cn_phrase_char=8'd21;
            10'd753:cn_phrase_char=8'd104;
            10'd754:cn_phrase_char=8'd111;
            10'd755:cn_phrase_char=8'd112;
            10'd756:cn_phrase_char=8'd113;
            10'd757:cn_phrase_char=8'd111;
            10'd758:cn_phrase_char=8'd96;
            10'd768:cn_phrase_char=8'd50;
            10'd769:cn_phrase_char=8'd109;
            10'd770:cn_phrase_char=8'd110;
            10'd771:cn_phrase_char=8'd63;
            10'd772:cn_phrase_char=8'd20;
            10'd773:cn_phrase_char=8'd109;
            10'd774:cn_phrase_char=8'd114;
            10'd784:cn_phrase_char=8'd71;
            10'd785:cn_phrase_char=8'd72;
            10'd786:cn_phrase_char=8'd73;
            10'd787:cn_phrase_char=8'd2;
            10'd788:cn_phrase_char=8'd3;
            10'd800:cn_phrase_char=8'd57;
            10'd801:cn_phrase_char=8'd58;
            10'd802:cn_phrase_char=8'd2;
            10'd803:cn_phrase_char=8'd3;
            10'd816:cn_phrase_char=8'd99;
            10'd817:cn_phrase_char=8'd11;
            10'd818:cn_phrase_char=8'd72;
            10'd819:cn_phrase_char=8'd73;
            10'd832:cn_phrase_char=8'd50;
            10'd833:cn_phrase_char=8'd115;
            10'd834:cn_phrase_char=8'd97;
            10'd848:cn_phrase_char=8'd116;
            10'd849:cn_phrase_char=8'd97;
            10'd850:cn_phrase_char=8'd111;
            10'd851:cn_phrase_char=8'd117;
            10'd864:cn_phrase_char=8'd50;
            10'd865:cn_phrase_char=8'd118;
            10'd866:cn_phrase_char=8'd64;
            10'd867:cn_phrase_char=8'd119;
            10'd868:cn_phrase_char=8'd120;
            10'd880:cn_phrase_char=8'd50;
            10'd881:cn_phrase_char=8'd86;
            10'd882:cn_phrase_char=8'd46;
            default:cn_phrase_char=8'd255;
        endcase end
    endfunction
    function [15:0] cn_glyph_row;
        input [7:0] glyph; input [3:0] row;
        begin case({glyph,row})
            12'd0:cn_glyph_row=16'h1040;
            12'd1:cn_glyph_row=16'h3040;
            12'd2:cn_glyph_row=16'h20c0;
            12'd3:cn_glyph_row=16'h3efe;
            12'd4:cn_glyph_row=16'h4686;
            12'd5:cn_glyph_row=16'h4484;
            12'd6:cn_glyph_row=16'h1120;
            12'd7:cn_glyph_row=16'h1020;
            12'd8:cn_glyph_row=16'h1020;
            12'd9:cn_glyph_row=16'h1070;
            12'd10:cn_glyph_row=16'h1050;
            12'd11:cn_glyph_row=16'h1cd8;
            12'd12:cn_glyph_row=16'h198c;
            12'd13:cn_glyph_row=16'h1306;
            12'd16:cn_glyph_row=16'h0808;
            12'd17:cn_glyph_row=16'h0808;
            12'd18:cn_glyph_row=16'h4ac8;
            12'd19:cn_glyph_row=16'h2e68;
            12'd20:cn_glyph_row=16'h0828;
            12'd21:cn_glyph_row=16'h7e88;
            12'd22:cn_glyph_row=16'h18c8;
            12'd23:cn_glyph_row=16'h1c68;
            12'd24:cn_glyph_row=16'h3a08;
            12'd25:cn_glyph_row=16'h2a3e;
            12'd26:cn_glyph_row=16'h49c8;
            12'd27:cn_glyph_row=16'h4808;
            12'd28:cn_glyph_row=16'h0808;
            12'd29:cn_glyph_row=16'h0808;
            12'd30:cn_glyph_row=16'h0808;
            12'd32:cn_glyph_row=16'h3000;
            12'd33:cn_glyph_row=16'h19fc;
            12'd34:cn_glyph_row=16'h0904;
            12'd35:cn_glyph_row=16'h0104;
            12'd36:cn_glyph_row=16'h0104;
            12'd37:cn_glyph_row=16'h7104;
            12'd38:cn_glyph_row=16'h1104;
            12'd39:cn_glyph_row=16'h11fc;
            12'd40:cn_glyph_row=16'h1000;
            12'd41:cn_glyph_row=16'h1400;
            12'd42:cn_glyph_row=16'h1c98;
            12'd43:cn_glyph_row=16'h190c;
            12'd44:cn_glyph_row=16'h3306;
            12'd45:cn_glyph_row=16'h0602;
            12'd48:cn_glyph_row=16'h0004;
            12'd49:cn_glyph_row=16'h3f04;
            12'd50:cn_glyph_row=16'h2124;
            12'd51:cn_glyph_row=16'h2124;
            12'd52:cn_glyph_row=16'h3f24;
            12'd53:cn_glyph_row=16'h3f24;
            12'd54:cn_glyph_row=16'h0824;
            12'd55:cn_glyph_row=16'h0824;
            12'd56:cn_glyph_row=16'h7fa4;
            12'd57:cn_glyph_row=16'h08a4;
            12'd58:cn_glyph_row=16'h08a4;
            12'd59:cn_glyph_row=16'h1884;
            12'd60:cn_glyph_row=16'h3084;
            12'd61:cn_glyph_row=16'h639c;
            12'd62:cn_glyph_row=16'h4000;
            12'd66:cn_glyph_row=16'h1800;
            12'd67:cn_glyph_row=16'h11fe;
            12'd68:cn_glyph_row=16'h2230;
            12'd69:cn_glyph_row=16'h2630;
            12'd70:cn_glyph_row=16'h7c30;
            12'd71:cn_glyph_row=16'h0830;
            12'd72:cn_glyph_row=16'h1830;
            12'd73:cn_glyph_row=16'h3030;
            12'd74:cn_glyph_row=16'h7e30;
            12'd75:cn_glyph_row=16'h0030;
            12'd76:cn_glyph_row=16'h0230;
            12'd77:cn_glyph_row=16'h7c30;
            12'd78:cn_glyph_row=16'h61fe;
            12'd80:cn_glyph_row=16'h0600;
            12'd81:cn_glyph_row=16'h0400;
            12'd82:cn_glyph_row=16'h0fe0;
            12'd83:cn_glyph_row=16'h1860;
            12'd84:cn_glyph_row=16'h3040;
            12'd85:cn_glyph_row=16'h7ff8;
            12'd86:cn_glyph_row=16'h1088;
            12'd87:cn_glyph_row=16'h1088;
            12'd88:cn_glyph_row=16'h1ff8;
            12'd89:cn_glyph_row=16'h1008;
            12'd90:cn_glyph_row=16'h1000;
            12'd91:cn_glyph_row=16'h1000;
            12'd92:cn_glyph_row=16'h1806;
            12'd93:cn_glyph_row=16'h1ffc;
            12'd96:cn_glyph_row=16'h0030;
            12'd97:cn_glyph_row=16'h0030;
            12'd98:cn_glyph_row=16'h3e30;
            12'd99:cn_glyph_row=16'h0030;
            12'd100:cn_glyph_row=16'h00fe;
            12'd101:cn_glyph_row=16'h7f32;
            12'd102:cn_glyph_row=16'h7f22;
            12'd103:cn_glyph_row=16'h1022;
            12'd104:cn_glyph_row=16'h1622;
            12'd105:cn_glyph_row=16'h2222;
            12'd106:cn_glyph_row=16'h2362;
            12'd107:cn_glyph_row=16'h7d46;
            12'd108:cn_glyph_row=16'h00c6;
            12'd109:cn_glyph_row=16'h019c;
            12'd112:cn_glyph_row=16'h0100;
            12'd113:cn_glyph_row=16'h0100;
            12'd114:cn_glyph_row=16'h7ffe;
            12'd115:cn_glyph_row=16'h0240;
            12'd116:cn_glyph_row=16'h0660;
            12'd117:cn_glyph_row=16'h0420;
            12'd118:cn_glyph_row=16'h1b18;
            12'd119:cn_glyph_row=16'h310e;
            12'd120:cn_glyph_row=16'h6000;
            12'd121:cn_glyph_row=16'h0080;
            12'd122:cn_glyph_row=16'h248c;
            12'd123:cn_glyph_row=16'h2406;
            12'd124:cn_glyph_row=16'h6412;
            12'd125:cn_glyph_row=16'h47f0;
            12'd128:cn_glyph_row=16'h3ffc;
            12'd129:cn_glyph_row=16'h2304;
            12'd130:cn_glyph_row=16'h23e4;
            12'd131:cn_glyph_row=16'h2664;
            12'd132:cn_glyph_row=16'h2f44;
            12'd133:cn_glyph_row=16'h2184;
            12'd134:cn_glyph_row=16'h2674;
            12'd135:cn_glyph_row=16'h2994;
            12'd136:cn_glyph_row=16'h20c4;
            12'd137:cn_glyph_row=16'h2304;
            12'd138:cn_glyph_row=16'h20c4;
            12'd139:cn_glyph_row=16'h2004;
            12'd140:cn_glyph_row=16'h3ffc;
            12'd141:cn_glyph_row=16'h2006;
            12'd144:cn_glyph_row=16'h1880;
            12'd145:cn_glyph_row=16'h1100;
            12'd146:cn_glyph_row=16'h13f0;
            12'd147:cn_glyph_row=16'h37fc;
            12'd148:cn_glyph_row=16'h3664;
            12'd149:cn_glyph_row=16'h7244;
            12'd150:cn_glyph_row=16'h53fc;
            12'd151:cn_glyph_row=16'h11c8;
            12'd152:cn_glyph_row=16'h1658;
            12'd153:cn_glyph_row=16'h11a8;
            12'd154:cn_glyph_row=16'h1768;
            12'd155:cn_glyph_row=16'h14a4;
            12'd156:cn_glyph_row=16'h1322;
            12'd157:cn_glyph_row=16'h1460;
            12'd158:cn_glyph_row=16'h0040;
            12'd160:cn_glyph_row=16'h1060;
            12'd161:cn_glyph_row=16'h3f7e;
            12'd162:cn_glyph_row=16'h6cd8;
            12'd164:cn_glyph_row=16'h1ff8;
            12'd165:cn_glyph_row=16'h1ff8;
            12'd166:cn_glyph_row=16'h1008;
            12'd167:cn_glyph_row=16'h1ff8;
            12'd168:cn_glyph_row=16'h1008;
            12'd169:cn_glyph_row=16'h1ff8;
            12'd170:cn_glyph_row=16'h0220;
            12'd171:cn_glyph_row=16'h7ffe;
            12'd172:cn_glyph_row=16'h0420;
            12'd173:cn_glyph_row=16'h3820;
            12'd174:cn_glyph_row=16'h0020;
            12'd176:cn_glyph_row=16'h0060;
            12'd177:cn_glyph_row=16'h3060;
            12'd178:cn_glyph_row=16'h1860;
            12'd179:cn_glyph_row=16'h03fc;
            12'd180:cn_glyph_row=16'h0060;
            12'd181:cn_glyph_row=16'h6060;
            12'd182:cn_glyph_row=16'h3060;
            12'd183:cn_glyph_row=16'h07fe;
            12'd184:cn_glyph_row=16'h00c0;
            12'd185:cn_glyph_row=16'h0880;
            12'd186:cn_glyph_row=16'h1998;
            12'd187:cn_glyph_row=16'h310c;
            12'd188:cn_glyph_row=16'h220c;
            12'd189:cn_glyph_row=16'h63f6;
            12'd192:cn_glyph_row=16'h0100;
            12'd193:cn_glyph_row=16'h0180;
            12'd194:cn_glyph_row=16'h3ffc;
            12'd195:cn_glyph_row=16'h2004;
            12'd196:cn_glyph_row=16'h2044;
            12'd197:cn_glyph_row=16'h0640;
            12'd198:cn_glyph_row=16'h1040;
            12'd199:cn_glyph_row=16'h1840;
            12'd200:cn_glyph_row=16'h0040;
            12'd201:cn_glyph_row=16'h7ffe;
            12'd202:cn_glyph_row=16'h0080;
            12'd203:cn_glyph_row=16'h0120;
            12'd204:cn_glyph_row=16'h0638;
            12'd205:cn_glyph_row=16'h7c0e;
            12'd206:cn_glyph_row=16'h2000;
            12'd208:cn_glyph_row=16'h0008;
            12'd209:cn_glyph_row=16'h0008;
            12'd210:cn_glyph_row=16'h7c08;
            12'd211:cn_glyph_row=16'h65fe;
            12'd212:cn_glyph_row=16'h65fe;
            12'd213:cn_glyph_row=16'h6408;
            12'd214:cn_glyph_row=16'h7c88;
            12'd215:cn_glyph_row=16'h64c8;
            12'd216:cn_glyph_row=16'h6448;
            12'd217:cn_glyph_row=16'h6408;
            12'd218:cn_glyph_row=16'h7c08;
            12'd219:cn_glyph_row=16'h6408;
            12'd220:cn_glyph_row=16'h6008;
            12'd221:cn_glyph_row=16'h0038;
            12'd224:cn_glyph_row=16'h1888;
            12'd225:cn_glyph_row=16'h18d8;
            12'd226:cn_glyph_row=16'h1810;
            12'd227:cn_glyph_row=16'h19fe;
            12'd228:cn_glyph_row=16'h7c20;
            12'd229:cn_glyph_row=16'h1820;
            12'd230:cn_glyph_row=16'h19fe;
            12'd231:cn_glyph_row=16'h3c20;
            12'd232:cn_glyph_row=16'h3e20;
            12'd233:cn_glyph_row=16'h5820;
            12'd234:cn_glyph_row=16'h5bfe;
            12'd235:cn_glyph_row=16'h1820;
            12'd236:cn_glyph_row=16'h1820;
            12'd237:cn_glyph_row=16'h1820;
            12'd238:cn_glyph_row=16'h0020;
            12'd240:cn_glyph_row=16'h0180;
            12'd241:cn_glyph_row=16'h0180;
            12'd242:cn_glyph_row=16'h0180;
            12'd243:cn_glyph_row=16'h7ffe;
            12'd244:cn_glyph_row=16'h03c0;
            12'd245:cn_glyph_row=16'h03c0;
            12'd246:cn_glyph_row=16'h07e0;
            12'd247:cn_glyph_row=16'h05a0;
            12'd248:cn_glyph_row=16'h0db0;
            12'd249:cn_glyph_row=16'h1998;
            12'd250:cn_glyph_row=16'h37fc;
            12'd251:cn_glyph_row=16'h67f6;
            12'd252:cn_glyph_row=16'h0180;
            12'd253:cn_glyph_row=16'h0180;
            12'd254:cn_glyph_row=16'h0180;
            12'd256:cn_glyph_row=16'h0080;
            12'd257:cn_glyph_row=16'h0080;
            12'd258:cn_glyph_row=16'h3ffe;
            12'd259:cn_glyph_row=16'h2080;
            12'd260:cn_glyph_row=16'h2100;
            12'd261:cn_glyph_row=16'h2ffc;
            12'd262:cn_glyph_row=16'h2240;
            12'd263:cn_glyph_row=16'h2640;
            12'd264:cn_glyph_row=16'h27fc;
            12'd265:cn_glyph_row=16'h2040;
            12'd266:cn_glyph_row=16'h2040;
            12'd267:cn_glyph_row=16'h3ffe;
            12'd268:cn_glyph_row=16'h6040;
            12'd269:cn_glyph_row=16'h4040;
            12'd270:cn_glyph_row=16'h0040;
            12'd272:cn_glyph_row=16'h0240;
            12'd273:cn_glyph_row=16'h0244;
            12'd274:cn_glyph_row=16'h7e78;
            12'd275:cn_glyph_row=16'h0240;
            12'd276:cn_glyph_row=16'h7e42;
            12'd277:cn_glyph_row=16'h423e;
            12'd279:cn_glyph_row=16'h1ff8;
            12'd280:cn_glyph_row=16'h1808;
            12'd281:cn_glyph_row=16'h1ff8;
            12'd282:cn_glyph_row=16'h1808;
            12'd283:cn_glyph_row=16'h1ff8;
            12'd284:cn_glyph_row=16'h1808;
            12'd285:cn_glyph_row=16'h1838;
            12'd286:cn_glyph_row=16'h1820;
            12'd288:cn_glyph_row=16'h1ff8;
            12'd289:cn_glyph_row=16'h1008;
            12'd290:cn_glyph_row=16'h1ff8;
            12'd291:cn_glyph_row=16'h1008;
            12'd292:cn_glyph_row=16'h1ff8;
            12'd293:cn_glyph_row=16'h0100;
            12'd294:cn_glyph_row=16'h7ffe;
            12'd296:cn_glyph_row=16'h1ff8;
            12'd297:cn_glyph_row=16'h1808;
            12'd298:cn_glyph_row=16'h1ff8;
            12'd299:cn_glyph_row=16'h0080;
            12'd300:cn_glyph_row=16'h1c98;
            12'd301:cn_glyph_row=16'h3384;
            12'd302:cn_glyph_row=16'h2300;
            12'd304:cn_glyph_row=16'h3ff8;
            12'd305:cn_glyph_row=16'h0008;
            12'd306:cn_glyph_row=16'h1ff8;
            12'd307:cn_glyph_row=16'h0018;
            12'd308:cn_glyph_row=16'h0018;
            12'd309:cn_glyph_row=16'h7ffe;
            12'd310:cn_glyph_row=16'h0188;
            12'd311:cn_glyph_row=16'h199c;
            12'd312:cn_glyph_row=16'h09f0;
            12'd313:cn_glyph_row=16'h07e0;
            12'd314:cn_glyph_row=16'h19b0;
            12'd315:cn_glyph_row=16'h618e;
            12'd316:cn_glyph_row=16'h0384;
            12'd317:cn_glyph_row=16'h0200;
            12'd320:cn_glyph_row=16'h0400;
            12'd321:cn_glyph_row=16'h0600;
            12'd322:cn_glyph_row=16'h0300;
            12'd323:cn_glyph_row=16'h0180;
            12'd324:cn_glyph_row=16'h0180;
            12'd325:cn_glyph_row=16'h01c0;
            12'd326:cn_glyph_row=16'h0340;
            12'd327:cn_glyph_row=16'h0260;
            12'd328:cn_glyph_row=16'h0620;
            12'd329:cn_glyph_row=16'h0c30;
            12'd330:cn_glyph_row=16'h0818;
            12'd331:cn_glyph_row=16'h181c;
            12'd332:cn_glyph_row=16'h700e;
            12'd333:cn_glyph_row=16'h6000;
            12'd336:cn_glyph_row=16'h0300;
            12'd337:cn_glyph_row=16'h0200;
            12'd338:cn_glyph_row=16'h0200;
            12'd339:cn_glyph_row=16'h3ffc;
            12'd340:cn_glyph_row=16'h3004;
            12'd341:cn_glyph_row=16'h3004;
            12'd342:cn_glyph_row=16'h3004;
            12'd343:cn_glyph_row=16'h3ffc;
            12'd344:cn_glyph_row=16'h3004;
            12'd345:cn_glyph_row=16'h3004;
            12'd346:cn_glyph_row=16'h3004;
            12'd347:cn_glyph_row=16'h3004;
            12'd348:cn_glyph_row=16'h3ffc;
            12'd349:cn_glyph_row=16'h3004;
            12'd352:cn_glyph_row=16'h3ffc;
            12'd353:cn_glyph_row=16'h0180;
            12'd354:cn_glyph_row=16'h1188;
            12'd355:cn_glyph_row=16'h1998;
            12'd356:cn_glyph_row=16'h0d90;
            12'd357:cn_glyph_row=16'h05a0;
            12'd358:cn_glyph_row=16'h0180;
            12'd359:cn_glyph_row=16'h7ffe;
            12'd360:cn_glyph_row=16'h0180;
            12'd361:cn_glyph_row=16'h0180;
            12'd362:cn_glyph_row=16'h0180;
            12'd363:cn_glyph_row=16'h0180;
            12'd364:cn_glyph_row=16'h0180;
            12'd365:cn_glyph_row=16'h0180;
            12'd368:cn_glyph_row=16'h0100;
            12'd369:cn_glyph_row=16'h1200;
            12'd370:cn_glyph_row=16'h35ce;
            12'd371:cn_glyph_row=16'h6080;
            12'd372:cn_glyph_row=16'h17e0;
            12'd373:cn_glyph_row=16'h14be;
            12'd374:cn_glyph_row=16'h37e4;
            12'd375:cn_glyph_row=16'h74a4;
            12'd376:cn_glyph_row=16'h77e4;
            12'd377:cn_glyph_row=16'h3104;
            12'd378:cn_glyph_row=16'h3ff4;
            12'd379:cn_glyph_row=16'h3184;
            12'd380:cn_glyph_row=16'h3664;
            12'd381:cn_glyph_row=16'h3c2c;
            12'd382:cn_glyph_row=16'h3008;
            12'd384:cn_glyph_row=16'h10b0;
            12'd385:cn_glyph_row=16'h3190;
            12'd386:cn_glyph_row=16'h2100;
            12'd387:cn_glyph_row=16'h2dfe;
            12'd388:cn_glyph_row=16'h4b30;
            12'd389:cn_glyph_row=16'h7b30;
            12'd390:cn_glyph_row=16'h15fc;
            12'd391:cn_glyph_row=16'h1130;
            12'd392:cn_glyph_row=16'h2130;
            12'd393:cn_glyph_row=16'h79fc;
            12'd394:cn_glyph_row=16'h0130;
            12'd395:cn_glyph_row=16'h0130;
            12'd396:cn_glyph_row=16'h7dfe;
            12'd397:cn_glyph_row=16'h4100;
            12'd398:cn_glyph_row=16'h0100;
            12'd400:cn_glyph_row=16'h1820;
            12'd401:cn_glyph_row=16'h1810;
            12'd402:cn_glyph_row=16'h1800;
            12'd403:cn_glyph_row=16'h18fe;
            12'd404:cn_glyph_row=16'h7e82;
            12'd405:cn_glyph_row=16'h1882;
            12'd406:cn_glyph_row=16'h1882;
            12'd407:cn_glyph_row=16'h1efe;
            12'd408:cn_glyph_row=16'h7886;
            12'd409:cn_glyph_row=16'h1880;
            12'd410:cn_glyph_row=16'h1980;
            12'd411:cn_glyph_row=16'h1900;
            12'd412:cn_glyph_row=16'h1900;
            12'd413:cn_glyph_row=16'h3200;
            12'd414:cn_glyph_row=16'h0200;
            12'd416:cn_glyph_row=16'h2060;
            12'd417:cn_glyph_row=16'h3060;
            12'd418:cn_glyph_row=16'h18b0;
            12'd419:cn_glyph_row=16'h0198;
            12'd420:cn_glyph_row=16'h010c;
            12'd421:cn_glyph_row=16'h7666;
            12'd422:cn_glyph_row=16'h10c0;
            12'd423:cn_glyph_row=16'h1198;
            12'd424:cn_glyph_row=16'h1130;
            12'd425:cn_glyph_row=16'h1064;
            12'd426:cn_glyph_row=16'h15ce;
            12'd427:cn_glyph_row=16'h1c18;
            12'd428:cn_glyph_row=16'h1830;
            12'd429:cn_glyph_row=16'h13c0;
            12'd430:cn_glyph_row=16'h0100;
            12'd432:cn_glyph_row=16'h0400;
            12'd433:cn_glyph_row=16'h74fe;
            12'd434:cn_glyph_row=16'h7520;
            12'd435:cn_glyph_row=16'h7d20;
            12'd436:cn_glyph_row=16'h6420;
            12'd437:cn_glyph_row=16'h7fbe;
            12'd438:cn_glyph_row=16'h6424;
            12'd439:cn_glyph_row=16'h6d24;
            12'd440:cn_glyph_row=16'h6da4;
            12'd441:cn_glyph_row=16'h74e4;
            12'd442:cn_glyph_row=16'h6444;
            12'd443:cn_glyph_row=16'h6044;
            12'd444:cn_glyph_row=16'h7f44;
            12'd445:cn_glyph_row=16'h0084;
            12'd448:cn_glyph_row=16'h0420;
            12'd449:cn_glyph_row=16'h0420;
            12'd450:cn_glyph_row=16'h7ffe;
            12'd451:cn_glyph_row=16'h0420;
            12'd452:cn_glyph_row=16'h7ffe;
            12'd453:cn_glyph_row=16'h4002;
            12'd454:cn_glyph_row=16'h4ff2;
            12'd455:cn_glyph_row=16'h0810;
            12'd456:cn_glyph_row=16'h0810;
            12'd457:cn_glyph_row=16'h0ff0;
            12'd458:cn_glyph_row=16'h1ff8;
            12'd459:cn_glyph_row=16'h1008;
            12'd460:cn_glyph_row=16'h1008;
            12'd461:cn_glyph_row=16'h1ff8;
            12'd462:cn_glyph_row=16'h1000;
            12'd464:cn_glyph_row=16'h0420;
            12'd465:cn_glyph_row=16'h0620;
            12'd466:cn_glyph_row=16'h3ffc;
            12'd467:cn_glyph_row=16'h0100;
            12'd468:cn_glyph_row=16'h1ff8;
            12'd469:cn_glyph_row=16'h0100;
            12'd470:cn_glyph_row=16'h7ffc;
            12'd471:cn_glyph_row=16'h0240;
            12'd472:cn_glyph_row=16'h0420;
            12'd473:cn_glyph_row=16'h1a38;
            12'd474:cn_glyph_row=16'h6626;
            12'd475:cn_glyph_row=16'h0420;
            12'd476:cn_glyph_row=16'h0420;
            12'd477:cn_glyph_row=16'h1820;
            12'd478:cn_glyph_row=16'h1020;
            12'd480:cn_glyph_row=16'h1040;
            12'd481:cn_glyph_row=16'h1040;
            12'd482:cn_glyph_row=16'h1040;
            12'd483:cn_glyph_row=16'h1bf8;
            12'd484:cn_glyph_row=16'h5448;
            12'd485:cn_glyph_row=16'h5448;
            12'd486:cn_glyph_row=16'h5048;
            12'd487:cn_glyph_row=16'h53fe;
            12'd488:cn_glyph_row=16'h1060;
            12'd489:cn_glyph_row=16'h10e0;
            12'd490:cn_glyph_row=16'h1090;
            12'd491:cn_glyph_row=16'h1198;
            12'd492:cn_glyph_row=16'h130c;
            12'd493:cn_glyph_row=16'h1606;
            12'd494:cn_glyph_row=16'h1000;
            12'd496:cn_glyph_row=16'h10c0;
            12'd497:cn_glyph_row=16'h1058;
            12'd498:cn_glyph_row=16'h3048;
            12'd499:cn_glyph_row=16'h2644;
            12'd500:cn_glyph_row=16'h4df8;
            12'd501:cn_glyph_row=16'h7b40;
            12'd502:cn_glyph_row=16'h105e;
            12'd503:cn_glyph_row=16'h13f0;
            12'd504:cn_glyph_row=16'h224c;
            12'd505:cn_glyph_row=16'h7c68;
            12'd506:cn_glyph_row=16'h0030;
            12'd507:cn_glyph_row=16'h1c70;
            12'd508:cn_glyph_row=16'h70da;
            12'd509:cn_glyph_row=16'h030e;
            12'd512:cn_glyph_row=16'h1860;
            12'd513:cn_glyph_row=16'h1840;
            12'd514:cn_glyph_row=16'h18fc;
            12'd515:cn_glyph_row=16'h1e88;
            12'd516:cn_glyph_row=16'h5d08;
            12'd517:cn_glyph_row=16'h5818;
            12'd518:cn_glyph_row=16'h51de;
            12'd519:cn_glyph_row=16'h1102;
            12'd520:cn_glyph_row=16'h1102;
            12'd521:cn_glyph_row=16'h19de;
            12'd522:cn_glyph_row=16'h3d02;
            12'd523:cn_glyph_row=16'h2502;
            12'd524:cn_glyph_row=16'h61fe;
            12'd525:cn_glyph_row=16'hc102;
            12'd528:cn_glyph_row=16'h1820;
            12'd529:cn_glyph_row=16'h1020;
            12'd530:cn_glyph_row=16'h11fe;
            12'd531:cn_glyph_row=16'h1008;
            12'd532:cn_glyph_row=16'h5488;
            12'd533:cn_glyph_row=16'h5848;
            12'd534:cn_glyph_row=16'h53fe;
            12'd535:cn_glyph_row=16'h5000;
            12'd536:cn_glyph_row=16'h1000;
            12'd537:cn_glyph_row=16'h18fc;
            12'd538:cn_glyph_row=16'h3c84;
            12'd539:cn_glyph_row=16'h2684;
            12'd540:cn_glyph_row=16'h60fc;
            12'd541:cn_glyph_row=16'h4084;
            12'd542:cn_glyph_row=16'h0180;
            12'd544:cn_glyph_row=16'h0430;
            12'd545:cn_glyph_row=16'h0620;
            12'd546:cn_glyph_row=16'h3ffc;
            12'd547:cn_glyph_row=16'h0180;
            12'd548:cn_glyph_row=16'h0180;
            12'd549:cn_glyph_row=16'h1ff8;
            12'd550:cn_glyph_row=16'h0180;
            12'd551:cn_glyph_row=16'h7ffe;
            12'd552:cn_glyph_row=16'h0180;
            12'd553:cn_glyph_row=16'h3ffc;
            12'd554:cn_glyph_row=16'h0180;
            12'd555:cn_glyph_row=16'h0340;
            12'd556:cn_glyph_row=16'h0630;
            12'd557:cn_glyph_row=16'h381e;
            12'd558:cn_glyph_row=16'h2000;
            12'd560:cn_glyph_row=16'h0060;
            12'd561:cn_glyph_row=16'h3060;
            12'd562:cn_glyph_row=16'h1860;
            12'd563:cn_glyph_row=16'h0060;
            12'd564:cn_glyph_row=16'h0060;
            12'd565:cn_glyph_row=16'h67fe;
            12'd566:cn_glyph_row=16'h3060;
            12'd567:cn_glyph_row=16'h0060;
            12'd568:cn_glyph_row=16'h0060;
            12'd569:cn_glyph_row=16'h1060;
            12'd570:cn_glyph_row=16'h3060;
            12'd571:cn_glyph_row=16'h2060;
            12'd572:cn_glyph_row=16'h6060;
            12'd573:cn_glyph_row=16'h6060;
            12'd574:cn_glyph_row=16'h0060;
            12'd576:cn_glyph_row=16'h2000;
            12'd577:cn_glyph_row=16'h37fe;
            12'd578:cn_glyph_row=16'h1420;
            12'd579:cn_glyph_row=16'h04fc;
            12'd580:cn_glyph_row=16'h44fc;
            12'd581:cn_glyph_row=16'h3484;
            12'd582:cn_glyph_row=16'h04fc;
            12'd583:cn_glyph_row=16'h0484;
            12'd584:cn_glyph_row=16'h14fc;
            12'd585:cn_glyph_row=16'h3420;
            12'd586:cn_glyph_row=16'h2424;
            12'd587:cn_glyph_row=16'h2da4;
            12'd588:cn_glyph_row=16'h6b22;
            12'd589:cn_glyph_row=16'h5a62;
            12'd590:cn_glyph_row=16'h0060;
            12'd592:cn_glyph_row=16'h7ffe;
            12'd593:cn_glyph_row=16'h0100;
            12'd594:cn_glyph_row=16'h0100;
            12'd595:cn_glyph_row=16'h1ff8;
            12'd596:cn_glyph_row=16'h1008;
            12'd597:cn_glyph_row=16'h1008;
            12'd598:cn_glyph_row=16'h1008;
            12'd599:cn_glyph_row=16'h1ff8;
            12'd600:cn_glyph_row=16'h1008;
            12'd601:cn_glyph_row=16'h1008;
            12'd602:cn_glyph_row=16'h1008;
            12'd603:cn_glyph_row=16'h1ff8;
            12'd604:cn_glyph_row=16'h1008;
            12'd605:cn_glyph_row=16'h1000;
            12'd608:cn_glyph_row=16'h0180;
            12'd609:cn_glyph_row=16'h7ffe;
            12'd610:cn_glyph_row=16'h0180;
            12'd611:cn_glyph_row=16'h1ff8;
            12'd612:cn_glyph_row=16'h1188;
            12'd613:cn_glyph_row=16'h1ff8;
            12'd614:cn_glyph_row=16'h0180;
            12'd615:cn_glyph_row=16'h3ff8;
            12'd616:cn_glyph_row=16'h0188;
            12'd617:cn_glyph_row=16'h7ffe;
            12'd618:cn_glyph_row=16'h0188;
            12'd619:cn_glyph_row=16'h3ff8;
            12'd620:cn_glyph_row=16'h0188;
            12'd621:cn_glyph_row=16'h0300;
            12'd622:cn_glyph_row=16'h0200;
            12'd625:cn_glyph_row=16'h7ffe;
            12'd626:cn_glyph_row=16'h0018;
            12'd627:cn_glyph_row=16'h0018;
            12'd628:cn_glyph_row=16'h1f98;
            12'd629:cn_glyph_row=16'h1098;
            12'd630:cn_glyph_row=16'h1098;
            12'd631:cn_glyph_row=16'h1098;
            12'd632:cn_glyph_row=16'h1098;
            12'd633:cn_glyph_row=16'h1f98;
            12'd634:cn_glyph_row=16'h1098;
            12'd635:cn_glyph_row=16'h1018;
            12'd636:cn_glyph_row=16'h0018;
            12'd637:cn_glyph_row=16'h0078;
            12'd638:cn_glyph_row=16'h0060;
            12'd640:cn_glyph_row=16'h0008;
            12'd641:cn_glyph_row=16'h1ff8;
            12'd642:cn_glyph_row=16'h1000;
            12'd643:cn_glyph_row=16'h1080;
            12'd644:cn_glyph_row=16'h1080;
            12'd645:cn_glyph_row=16'h3080;
            12'd646:cn_glyph_row=16'h3ffe;
            12'd647:cn_glyph_row=16'h2080;
            12'd648:cn_glyph_row=16'h0080;
            12'd649:cn_glyph_row=16'h0c90;
            12'd650:cn_glyph_row=16'h1898;
            12'd651:cn_glyph_row=16'h308c;
            12'd652:cn_glyph_row=16'h2084;
            12'd653:cn_glyph_row=16'h0380;
            12'd654:cn_glyph_row=16'h0200;
            12'd657:cn_glyph_row=16'h1ff8;
            12'd658:cn_glyph_row=16'h0080;
            12'd659:cn_glyph_row=16'h7ffe;
            12'd660:cn_glyph_row=16'h6082;
            12'd661:cn_glyph_row=16'h6efa;
            12'd662:cn_glyph_row=16'h1eb8;
            12'd664:cn_glyph_row=16'h2000;
            12'd665:cn_glyph_row=16'h3ffc;
            12'd666:cn_glyph_row=16'h000c;
            12'd667:cn_glyph_row=16'h1ffc;
            12'd668:cn_glyph_row=16'h000c;
            12'd669:cn_glyph_row=16'h1ffc;
            12'd670:cn_glyph_row=16'h000c;
            12'd672:cn_glyph_row=16'h0030;
            12'd673:cn_glyph_row=16'h3ffc;
            12'd674:cn_glyph_row=16'h0884;
            12'd675:cn_glyph_row=16'h3e84;
            12'd676:cn_glyph_row=16'h08fc;
            12'd677:cn_glyph_row=16'h0b84;
            12'd678:cn_glyph_row=16'h7cfc;
            12'd680:cn_glyph_row=16'h7ffe;
            12'd681:cn_glyph_row=16'h0400;
            12'd682:cn_glyph_row=16'h0ff8;
            12'd683:cn_glyph_row=16'h1808;
            12'd684:cn_glyph_row=16'h6808;
            12'd685:cn_glyph_row=16'h0ff8;
            12'd686:cn_glyph_row=16'h0808;
            12'd688:cn_glyph_row=16'h0100;
            12'd689:cn_glyph_row=16'h0100;
            12'd690:cn_glyph_row=16'h0100;
            12'd691:cn_glyph_row=16'h3ff8;
            12'd692:cn_glyph_row=16'h0100;
            12'd693:cn_glyph_row=16'h0100;
            12'd694:cn_glyph_row=16'h7ffe;
            12'd695:cn_glyph_row=16'h0380;
            12'd696:cn_glyph_row=16'h0740;
            12'd697:cn_glyph_row=16'h0d60;
            12'd698:cn_glyph_row=16'h1930;
            12'd699:cn_glyph_row=16'h311c;
            12'd700:cn_glyph_row=16'h6106;
            12'd701:cn_glyph_row=16'h0100;
            12'd704:cn_glyph_row=16'h0800;
            12'd705:cn_glyph_row=16'h19fc;
            12'd706:cn_glyph_row=16'h110c;
            12'd707:cn_glyph_row=16'h110c;
            12'd708:cn_glyph_row=16'h31fc;
            12'd709:cn_glyph_row=16'h3060;
            12'd710:cn_glyph_row=16'h5060;
            12'd711:cn_glyph_row=16'h57fe;
            12'd712:cn_glyph_row=16'h10f0;
            12'd713:cn_glyph_row=16'h11f0;
            12'd714:cn_glyph_row=16'h1178;
            12'd715:cn_glyph_row=16'h126c;
            12'd716:cn_glyph_row=16'h1666;
            12'd717:cn_glyph_row=16'h1060;
            12'd720:cn_glyph_row=16'h1020;
            12'd721:cn_glyph_row=16'h1020;
            12'd722:cn_glyph_row=16'h11fc;
            12'd723:cn_glyph_row=16'h7c20;
            12'd724:cn_glyph_row=16'h7c20;
            12'd725:cn_glyph_row=16'h1020;
            12'd726:cn_glyph_row=16'h13fe;
            12'd727:cn_glyph_row=16'h1c08;
            12'd728:cn_glyph_row=16'h73fe;
            12'd729:cn_glyph_row=16'h5008;
            12'd730:cn_glyph_row=16'h1108;
            12'd731:cn_glyph_row=16'h1188;
            12'd732:cn_glyph_row=16'h1088;
            12'd733:cn_glyph_row=16'h3038;
            12'd734:cn_glyph_row=16'h0030;
            12'd736:cn_glyph_row=16'h00c0;
            12'd737:cn_glyph_row=16'h7cf8;
            12'd738:cn_glyph_row=16'h1118;
            12'd739:cn_glyph_row=16'h1310;
            12'd740:cn_glyph_row=16'h12fc;
            12'd741:cn_glyph_row=16'h7c04;
            12'd742:cn_glyph_row=16'h31fc;
            12'd743:cn_glyph_row=16'h3804;
            12'd744:cn_glyph_row=16'h35fc;
            12'd745:cn_glyph_row=16'h5400;
            12'd746:cn_glyph_row=16'h50a0;
            12'd747:cn_glyph_row=16'h12a6;
            12'd748:cn_glyph_row=16'h128a;
            12'd749:cn_glyph_row=16'h10f8;
            12'd750:cn_glyph_row=16'h1000;
            12'd752:cn_glyph_row=16'h0100;
            12'd753:cn_glyph_row=16'h0180;
            12'd754:cn_glyph_row=16'h3ffc;
            12'd755:cn_glyph_row=16'h2004;
            12'd756:cn_glyph_row=16'h2004;
            12'd757:cn_glyph_row=16'h1ff8;
            12'd758:cn_glyph_row=16'h0080;
            12'd759:cn_glyph_row=16'h0080;
            12'd760:cn_glyph_row=16'h0880;
            12'd761:cn_glyph_row=16'h18f8;
            12'd762:cn_glyph_row=16'h1880;
            12'd763:cn_glyph_row=16'h3c80;
            12'd764:cn_glyph_row=16'h2780;
            12'd765:cn_glyph_row=16'h61fe;
            12'd768:cn_glyph_row=16'h1020;
            12'd769:cn_glyph_row=16'h3f7e;
            12'd770:cn_glyph_row=16'h64c8;
            12'd771:cn_glyph_row=16'h458c;
            12'd772:cn_glyph_row=16'h1ff8;
            12'd773:cn_glyph_row=16'h0180;
            12'd774:cn_glyph_row=16'h0180;
            12'd775:cn_glyph_row=16'hfffe;
            12'd776:cn_glyph_row=16'h0030;
            12'd777:cn_glyph_row=16'h0030;
            12'd778:cn_glyph_row=16'h3ffc;
            12'd779:cn_glyph_row=16'h0830;
            12'd780:cn_glyph_row=16'h0430;
            12'd781:cn_glyph_row=16'h0070;
            12'd784:cn_glyph_row=16'h0860;
            12'd785:cn_glyph_row=16'h1860;
            12'd786:cn_glyph_row=16'h13fc;
            12'd787:cn_glyph_row=16'h2060;
            12'd788:cn_glyph_row=16'h4c60;
            12'd789:cn_glyph_row=16'h0bfe;
            12'd790:cn_glyph_row=16'h1008;
            12'd791:cn_glyph_row=16'h3008;
            12'd792:cn_glyph_row=16'h77fe;
            12'd793:cn_glyph_row=16'h5008;
            12'd794:cn_glyph_row=16'h1188;
            12'd795:cn_glyph_row=16'h1088;
            12'd796:cn_glyph_row=16'h1018;
            12'd797:cn_glyph_row=16'h1038;
            12'd798:cn_glyph_row=16'h1000;
            12'd800:cn_glyph_row=16'h0020;
            12'd801:cn_glyph_row=16'h33fe;
            12'd802:cn_glyph_row=16'h1820;
            12'd803:cn_glyph_row=16'h03fc;
            12'd804:cn_glyph_row=16'h0020;
            12'd805:cn_glyph_row=16'h77fe;
            12'd806:cn_glyph_row=16'h1000;
            12'd807:cn_glyph_row=16'h11fc;
            12'd808:cn_glyph_row=16'h1104;
            12'd809:cn_glyph_row=16'h11fc;
            12'd810:cn_glyph_row=16'h1504;
            12'd811:cn_glyph_row=16'h19fc;
            12'd812:cn_glyph_row=16'h3104;
            12'd813:cn_glyph_row=16'h010c;
            12'd816:cn_glyph_row=16'h0180;
            12'd817:cn_glyph_row=16'h0980;
            12'd818:cn_glyph_row=16'h1980;
            12'd819:cn_glyph_row=16'h1ff8;
            12'd820:cn_glyph_row=16'h3180;
            12'd821:cn_glyph_row=16'h2180;
            12'd822:cn_glyph_row=16'h0180;
            12'd823:cn_glyph_row=16'h7ffe;
            12'd824:cn_glyph_row=16'h0640;
            12'd825:cn_glyph_row=16'h0440;
            12'd826:cn_glyph_row=16'h0440;
            12'd827:cn_glyph_row=16'h0c40;
            12'd828:cn_glyph_row=16'h1846;
            12'd829:cn_glyph_row=16'h707c;
            12'd832:cn_glyph_row=16'h0180;
            12'd833:cn_glyph_row=16'h0180;
            12'd834:cn_glyph_row=16'h3ffe;
            12'd835:cn_glyph_row=16'h2006;
            12'd836:cn_glyph_row=16'h2426;
            12'd837:cn_glyph_row=16'h0c38;
            12'd838:cn_glyph_row=16'h300e;
            12'd839:cn_glyph_row=16'h2004;
            12'd840:cn_glyph_row=16'h1ff8;
            12'd841:cn_glyph_row=16'h0180;
            12'd842:cn_glyph_row=16'h0180;
            12'd843:cn_glyph_row=16'h0180;
            12'd844:cn_glyph_row=16'h0180;
            12'd845:cn_glyph_row=16'h7ffe;
            12'd848:cn_glyph_row=16'h11fc;
            12'd849:cn_glyph_row=16'h11fc;
            12'd850:cn_glyph_row=16'h1010;
            12'd851:cn_glyph_row=16'h1020;
            12'd852:cn_glyph_row=16'h7c40;
            12'd853:cn_glyph_row=16'h11fe;
            12'd854:cn_glyph_row=16'h1152;
            12'd855:cn_glyph_row=16'h10d2;
            12'd856:cn_glyph_row=16'h1092;
            12'd857:cn_glyph_row=16'h15b2;
            12'd858:cn_glyph_row=16'h1f22;
            12'd859:cn_glyph_row=16'h6266;
            12'd860:cn_glyph_row=16'h00c6;
            12'd861:cn_glyph_row=16'h018c;
            12'd862:cn_glyph_row=16'h0100;
            12'd864:cn_glyph_row=16'h1800;
            12'd865:cn_glyph_row=16'h1000;
            12'd866:cn_glyph_row=16'h107e;
            12'd867:cn_glyph_row=16'h3f46;
            12'd868:cn_glyph_row=16'h2446;
            12'd869:cn_glyph_row=16'h6446;
            12'd870:cn_glyph_row=16'h0446;
            12'd871:cn_glyph_row=16'h7f46;
            12'd872:cn_glyph_row=16'h0c46;
            12'd873:cn_glyph_row=16'h0c46;
            12'd874:cn_glyph_row=16'h0e46;
            12'd875:cn_glyph_row=16'h137e;
            12'd876:cn_glyph_row=16'h3146;
            12'd877:cn_glyph_row=16'h6040;
            12'd880:cn_glyph_row=16'h0058;
            12'd881:cn_glyph_row=16'h004c;
            12'd882:cn_glyph_row=16'h0040;
            12'd883:cn_glyph_row=16'h3ffe;
            12'd884:cn_glyph_row=16'h3040;
            12'd885:cn_glyph_row=16'h3040;
            12'd886:cn_glyph_row=16'h3f4c;
            12'd887:cn_glyph_row=16'h2248;
            12'd888:cn_glyph_row=16'h2278;
            12'd889:cn_glyph_row=16'h2230;
            12'd890:cn_glyph_row=16'h2220;
            12'd891:cn_glyph_row=16'h2672;
            12'd892:cn_glyph_row=16'h6eda;
            12'd893:cn_glyph_row=16'h430e;
            12'd896:cn_glyph_row=16'h0060;
            12'd897:cn_glyph_row=16'h0060;
            12'd898:cn_glyph_row=16'h7e60;
            12'd899:cn_glyph_row=16'h1860;
            12'd900:cn_glyph_row=16'h19fe;
            12'd901:cn_glyph_row=16'h1866;
            12'd902:cn_glyph_row=16'h1866;
            12'd903:cn_glyph_row=16'h1844;
            12'd904:cn_glyph_row=16'h1844;
            12'd905:cn_glyph_row=16'h1844;
            12'd906:cn_glyph_row=16'h3ec4;
            12'd907:cn_glyph_row=16'h6084;
            12'd908:cn_glyph_row=16'h0104;
            12'd909:cn_glyph_row=16'h071c;
            12'd910:cn_glyph_row=16'h0200;
            12'd913:cn_glyph_row=16'h3ffc;
            12'd914:cn_glyph_row=16'h3ffc;
            12'd915:cn_glyph_row=16'h0080;
            12'd916:cn_glyph_row=16'h0080;
            12'd917:cn_glyph_row=16'h1880;
            12'd918:cn_glyph_row=16'h18fc;
            12'd919:cn_glyph_row=16'h18fc;
            12'd920:cn_glyph_row=16'h1880;
            12'd921:cn_glyph_row=16'h1880;
            12'd922:cn_glyph_row=16'h1880;
            12'd923:cn_glyph_row=16'h1880;
            12'd924:cn_glyph_row=16'h1880;
            12'd925:cn_glyph_row=16'h7ffe;
            12'd928:cn_glyph_row=16'h0100;
            12'd929:cn_glyph_row=16'h0300;
            12'd930:cn_glyph_row=16'h3ffe;
            12'd931:cn_glyph_row=16'h3ffe;
            12'd932:cn_glyph_row=16'h0660;
            12'd933:cn_glyph_row=16'h0460;
            12'd934:cn_glyph_row=16'h1860;
            12'd935:cn_glyph_row=16'h1bfc;
            12'd936:cn_glyph_row=16'h3860;
            12'd937:cn_glyph_row=16'h7860;
            12'd938:cn_glyph_row=16'h1860;
            12'd939:cn_glyph_row=16'h1860;
            12'd940:cn_glyph_row=16'h1860;
            12'd941:cn_glyph_row=16'h1ffe;
            12'd942:cn_glyph_row=16'h1800;
            12'd944:cn_glyph_row=16'h0008;
            12'd945:cn_glyph_row=16'h3ffc;
            12'd946:cn_glyph_row=16'h3108;
            12'd947:cn_glyph_row=16'h1108;
            12'd948:cn_glyph_row=16'h1998;
            12'd949:cn_glyph_row=16'h0830;
            12'd950:cn_glyph_row=16'h0100;
            12'd951:cn_glyph_row=16'h7ffe;
            12'd952:cn_glyph_row=16'h7ffe;
            12'd953:cn_glyph_row=16'h0740;
            12'd954:cn_glyph_row=16'h0d20;
            12'd955:cn_glyph_row=16'h1918;
            12'd956:cn_glyph_row=16'h710e;
            12'd957:cn_glyph_row=16'h4104;
            12'd958:cn_glyph_row=16'h0100;
            12'd960:cn_glyph_row=16'h3ffe;
            12'd962:cn_glyph_row=16'h0ff0;
            12'd963:cn_glyph_row=16'h0db0;
            12'd964:cn_glyph_row=16'h6db6;
            12'd965:cn_glyph_row=16'h6db6;
            12'd966:cn_glyph_row=16'h6ff6;
            12'd967:cn_glyph_row=16'h6db6;
            12'd968:cn_glyph_row=16'h6db6;
            12'd969:cn_glyph_row=16'h6ff6;
            12'd970:cn_glyph_row=16'h6006;
            12'd971:cn_glyph_row=16'h7ffe;
            12'd972:cn_glyph_row=16'h0006;
            12'd973:cn_glyph_row=16'h0006;
            12'd976:cn_glyph_row=16'h7ffe;
            12'd977:cn_glyph_row=16'h0100;
            12'd978:cn_glyph_row=16'h0300;
            12'd979:cn_glyph_row=16'h3ffc;
            12'd980:cn_glyph_row=16'h2644;
            12'd981:cn_glyph_row=16'h2644;
            12'd982:cn_glyph_row=16'h27c4;
            12'd983:cn_glyph_row=16'h2644;
            12'd984:cn_glyph_row=16'h27c4;
            12'd985:cn_glyph_row=16'h2644;
            12'd986:cn_glyph_row=16'h2644;
            12'd987:cn_glyph_row=16'h3ffc;
            12'd988:cn_glyph_row=16'h2004;
            12'd992:cn_glyph_row=16'h7ffe;
            12'd993:cn_glyph_row=16'h0080;
            12'd994:cn_glyph_row=16'h0100;
            12'd995:cn_glyph_row=16'h0300;
            12'd996:cn_glyph_row=16'h0760;
            12'd997:cn_glyph_row=16'h0530;
            12'd998:cn_glyph_row=16'h1918;
            12'd999:cn_glyph_row=16'h310c;
            12'd1000:cn_glyph_row=16'h6104;
            12'd1001:cn_glyph_row=16'h0100;
            12'd1002:cn_glyph_row=16'h0100;
            12'd1003:cn_glyph_row=16'h0100;
            12'd1004:cn_glyph_row=16'h0100;
            12'd1009:cn_glyph_row=16'h7ffe;
            12'd1010:cn_glyph_row=16'h6006;
            12'd1011:cn_glyph_row=16'h6c06;
            12'd1012:cn_glyph_row=16'h0c00;
            12'd1013:cn_glyph_row=16'h0ff8;
            12'd1014:cn_glyph_row=16'h0800;
            12'd1015:cn_glyph_row=16'h0800;
            12'd1016:cn_glyph_row=16'h0ffc;
            12'd1017:cn_glyph_row=16'h000c;
            12'd1018:cn_glyph_row=16'h000c;
            12'd1019:cn_glyph_row=16'h3fec;
            12'd1020:cn_glyph_row=16'h0008;
            12'd1021:cn_glyph_row=16'h0038;
            12'd1024:cn_glyph_row=16'h0120;
            12'd1025:cn_glyph_row=16'h4130;
            12'd1026:cn_glyph_row=16'h6300;
            12'd1027:cn_glyph_row=16'h33fe;
            12'd1028:cn_glyph_row=16'h1620;
            12'd1029:cn_glyph_row=16'h0620;
            12'd1030:cn_glyph_row=16'h0bfc;
            12'd1031:cn_glyph_row=16'h0220;
            12'd1032:cn_glyph_row=16'h1220;
            12'd1033:cn_glyph_row=16'h33fc;
            12'd1034:cn_glyph_row=16'h2220;
            12'd1035:cn_glyph_row=16'h6220;
            12'd1036:cn_glyph_row=16'h43fe;
            12'd1037:cn_glyph_row=16'h0200;
            12'd1038:cn_glyph_row=16'h0200;
            12'd1040:cn_glyph_row=16'h0600;
            12'd1041:cn_glyph_row=16'h0400;
            12'd1042:cn_glyph_row=16'h0ff0;
            12'd1043:cn_glyph_row=16'h1c30;
            12'd1044:cn_glyph_row=16'h3260;
            12'd1045:cn_glyph_row=16'h0180;
            12'd1046:cn_glyph_row=16'h07f0;
            12'd1047:cn_glyph_row=16'h781e;
            12'd1048:cn_glyph_row=16'h1ff8;
            12'd1049:cn_glyph_row=16'h1988;
            12'd1050:cn_glyph_row=16'h1ff8;
            12'd1051:cn_glyph_row=16'h1988;
            12'd1052:cn_glyph_row=16'h1988;
            12'd1053:cn_glyph_row=16'h1ff8;
            12'd1054:cn_glyph_row=16'h1808;
            12'd1057:cn_glyph_row=16'h3ff8;
            12'd1058:cn_glyph_row=16'h0180;
            12'd1059:cn_glyph_row=16'h7ffe;
            12'd1060:cn_glyph_row=16'h0180;
            12'd1061:cn_glyph_row=16'h1ff8;
            12'd1062:cn_glyph_row=16'h1188;
            12'd1063:cn_glyph_row=16'h1ff8;
            12'd1064:cn_glyph_row=16'h1188;
            12'd1065:cn_glyph_row=16'h1ff8;
            12'd1066:cn_glyph_row=16'h0180;
            12'd1067:cn_glyph_row=16'h3ffc;
            12'd1068:cn_glyph_row=16'h0180;
            12'd1069:cn_glyph_row=16'h7ffe;
            12'd1072:cn_glyph_row=16'h0806;
            12'd1073:cn_glyph_row=16'h0c78;
            12'd1074:cn_glyph_row=16'h7f60;
            12'd1075:cn_glyph_row=16'h2260;
            12'd1076:cn_glyph_row=16'h1260;
            12'd1077:cn_glyph_row=16'h7ffe;
            12'd1078:cn_glyph_row=16'h7fe4;
            12'd1079:cn_glyph_row=16'h0864;
            12'd1080:cn_glyph_row=16'h7fe4;
            12'd1081:cn_glyph_row=16'h0864;
            12'd1082:cn_glyph_row=16'h3a44;
            12'd1083:cn_glyph_row=16'h6944;
            12'd1084:cn_glyph_row=16'h48c4;
            12'd1085:cn_glyph_row=16'h1884;
            12'd1086:cn_glyph_row=16'h1084;
            12'd1088:cn_glyph_row=16'h1020;
            12'd1089:cn_glyph_row=16'h1030;
            12'd1090:cn_glyph_row=16'h13fe;
            12'd1091:cn_glyph_row=16'h7c00;
            12'd1092:cn_glyph_row=16'h1088;
            12'd1093:cn_glyph_row=16'h10cc;
            12'd1094:cn_glyph_row=16'h3106;
            12'd1095:cn_glyph_row=16'h3d08;
            12'd1096:cn_glyph_row=16'h7488;
            12'd1097:cn_glyph_row=16'h50d8;
            12'd1098:cn_glyph_row=16'h5070;
            12'd1099:cn_glyph_row=16'h1020;
            12'd1100:cn_glyph_row=16'h10d8;
            12'd1101:cn_glyph_row=16'h178e;
            12'd1102:cn_glyph_row=16'h0202;
            12'd1104:cn_glyph_row=16'h0180;
            12'd1105:cn_glyph_row=16'h0180;
            12'd1106:cn_glyph_row=16'h0240;
            12'd1107:cn_glyph_row=16'h0460;
            12'd1108:cn_glyph_row=16'h1818;
            12'd1109:cn_glyph_row=16'h3fee;
            12'd1110:cn_glyph_row=16'h6002;
            12'd1112:cn_glyph_row=16'h3ffc;
            12'd1113:cn_glyph_row=16'h0200;
            12'd1114:cn_glyph_row=16'h0300;
            12'd1115:cn_glyph_row=16'h0430;
            12'd1116:cn_glyph_row=16'h1818;
            12'd1117:cn_glyph_row=16'h1ffc;
            12'd1120:cn_glyph_row=16'h0040;
            12'd1121:cn_glyph_row=16'h27fc;
            12'd1122:cn_glyph_row=16'h1840;
            12'd1123:cn_glyph_row=16'h03fc;
            12'd1124:cn_glyph_row=16'h4040;
            12'd1125:cn_glyph_row=16'h67fe;
            12'd1126:cn_glyph_row=16'h1000;
            12'd1127:cn_glyph_row=16'h03fc;
            12'd1128:cn_glyph_row=16'h020c;
            12'd1129:cn_glyph_row=16'h1bfc;
            12'd1130:cn_glyph_row=16'h120c;
            12'd1131:cn_glyph_row=16'h23fc;
            12'd1132:cn_glyph_row=16'h220c;
            12'd1133:cn_glyph_row=16'h421c;
            12'd1134:cn_glyph_row=16'h0200;
            12'd1136:cn_glyph_row=16'h1060;
            12'd1137:cn_glyph_row=16'h1020;
            12'd1138:cn_glyph_row=16'h13fe;
            12'd1139:cn_glyph_row=16'h7b02;
            12'd1140:cn_glyph_row=16'h1362;
            12'd1141:cn_glyph_row=16'h1040;
            12'd1142:cn_glyph_row=16'h1040;
            12'd1143:cn_glyph_row=16'h1ffe;
            12'd1144:cn_glyph_row=16'h7088;
            12'd1145:cn_glyph_row=16'h5188;
            12'd1146:cn_glyph_row=16'h11d0;
            12'd1147:cn_glyph_row=16'h1070;
            12'd1148:cn_glyph_row=16'h107c;
            12'd1149:cn_glyph_row=16'h3786;
            12'd1152:cn_glyph_row=16'h0040;
            12'd1153:cn_glyph_row=16'h7ec0;
            12'd1154:cn_glyph_row=16'h10b8;
            12'd1155:cn_glyph_row=16'h1110;
            12'd1156:cn_glyph_row=16'h10fe;
            12'd1157:cn_glyph_row=16'h30b2;
            12'd1158:cn_glyph_row=16'h3cb2;
            12'd1159:cn_glyph_row=16'h64fe;
            12'd1160:cn_glyph_row=16'h64b2;
            12'd1161:cn_glyph_row=16'h24b2;
            12'd1162:cn_glyph_row=16'h24fe;
            12'd1163:cn_glyph_row=16'h3db2;
            12'd1164:cn_glyph_row=16'h2532;
            12'd1165:cn_glyph_row=16'h233e;
            12'd1166:cn_glyph_row=16'h0004;
            12'd1168:cn_glyph_row=16'h1060;
            12'd1169:cn_glyph_row=16'h1860;
            12'd1170:cn_glyph_row=16'h0c60;
            12'd1171:cn_glyph_row=16'h0060;
            12'd1172:cn_glyph_row=16'h0060;
            12'd1173:cn_glyph_row=16'h7060;
            12'd1174:cn_glyph_row=16'h1060;
            12'd1175:cn_glyph_row=16'h1060;
            12'd1176:cn_glyph_row=16'h10f0;
            12'd1177:cn_glyph_row=16'h1690;
            12'd1178:cn_glyph_row=16'h1d90;
            12'd1179:cn_glyph_row=16'h1908;
            12'd1180:cn_glyph_row=16'h130c;
            12'd1181:cn_glyph_row=16'h0606;
            12'd1184:cn_glyph_row=16'h0010;
            12'd1185:cn_glyph_row=16'h1010;
            12'd1186:cn_glyph_row=16'h23d6;
            12'd1187:cn_glyph_row=16'h2354;
            12'd1188:cn_glyph_row=16'h4f10;
            12'd1189:cn_glyph_row=16'h7b10;
            12'd1190:cn_glyph_row=16'h13fe;
            12'd1191:cn_glyph_row=16'h3330;
            12'd1192:cn_glyph_row=16'h633c;
            12'd1193:cn_glyph_row=16'h7b56;
            12'd1194:cn_glyph_row=16'h03d0;
            12'd1195:cn_glyph_row=16'h0310;
            12'd1196:cn_glyph_row=16'h7b00;
            12'd1197:cn_glyph_row=16'h43fe;
            12'd1200:cn_glyph_row=16'h1020;
            12'd1201:cn_glyph_row=16'h1020;
            12'd1202:cn_glyph_row=16'h21fe;
            12'd1203:cn_glyph_row=16'h2c20;
            12'd1204:cn_glyph_row=16'h49fe;
            12'd1205:cn_glyph_row=16'h7824;
            12'd1206:cn_glyph_row=16'h10f0;
            12'd1207:cn_glyph_row=16'h3130;
            12'd1208:cn_glyph_row=16'h25b0;
            12'd1209:cn_glyph_row=16'h7820;
            12'd1210:cn_glyph_row=16'h03fe;
            12'd1211:cn_glyph_row=16'h0c20;
            12'd1212:cn_glyph_row=16'h78dc;
            12'd1213:cn_glyph_row=16'h0386;
            12'd1216:cn_glyph_row=16'h2004;
            12'd1217:cn_glyph_row=16'h33fc;
            12'd1218:cn_glyph_row=16'h1300;
            12'd1219:cn_glyph_row=16'h0300;
            12'd1220:cn_glyph_row=16'h03fc;
            12'd1221:cn_glyph_row=16'h0308;
            12'd1222:cn_glyph_row=16'h7348;
            12'd1223:cn_glyph_row=16'h1368;
            12'd1224:cn_glyph_row=16'h1238;
            12'd1225:cn_glyph_row=16'h1238;
            12'd1226:cn_glyph_row=16'h166c;
            12'd1227:cn_glyph_row=16'h14c4;
            12'd1228:cn_glyph_row=16'h3800;
            12'd1229:cn_glyph_row=16'h67fe;
            12'd1233:cn_glyph_row=16'h3ffc;
            12'd1234:cn_glyph_row=16'h2004;
            12'd1235:cn_glyph_row=16'h2004;
            12'd1236:cn_glyph_row=16'h27e4;
            12'd1237:cn_glyph_row=16'h2424;
            12'd1238:cn_glyph_row=16'h2424;
            12'd1239:cn_glyph_row=16'h2424;
            12'd1240:cn_glyph_row=16'h27e4;
            12'd1241:cn_glyph_row=16'h27e4;
            12'd1242:cn_glyph_row=16'h2004;
            12'd1243:cn_glyph_row=16'h2004;
            12'd1244:cn_glyph_row=16'h3ffc;
            12'd1245:cn_glyph_row=16'h2004;
            12'd1248:cn_glyph_row=16'h7f7c;
            12'd1249:cn_glyph_row=16'h2244;
            12'd1250:cn_glyph_row=16'h2244;
            12'd1251:cn_glyph_row=16'h3e64;
            12'd1252:cn_glyph_row=16'h2224;
            12'd1253:cn_glyph_row=16'h2224;
            12'd1254:cn_glyph_row=16'h3e28;
            12'd1255:cn_glyph_row=16'h3e28;
            12'd1256:cn_glyph_row=16'h2218;
            12'd1257:cn_glyph_row=16'h2398;
            12'd1258:cn_glyph_row=16'h3e28;
            12'd1259:cn_glyph_row=16'h6266;
            12'd1260:cn_glyph_row=16'h02c2;
            12'd1261:cn_glyph_row=16'h0200;
            12'd1264:cn_glyph_row=16'h0020;
            12'd1265:cn_glyph_row=16'h3226;
            12'd1266:cn_glyph_row=16'h1b24;
            12'd1267:cn_glyph_row=16'h0124;
            12'd1268:cn_glyph_row=16'h0020;
            12'd1269:cn_glyph_row=16'h63fe;
            12'd1270:cn_glyph_row=16'h3206;
            12'd1271:cn_glyph_row=16'h03fe;
            12'd1272:cn_glyph_row=16'h03fe;
            12'd1273:cn_glyph_row=16'h1206;
            12'd1274:cn_glyph_row=16'h33fe;
            12'd1275:cn_glyph_row=16'h2206;
            12'd1276:cn_glyph_row=16'h2206;
            12'd1277:cn_glyph_row=16'h620e;
            12'd1278:cn_glyph_row=16'h2208;
            12'd1280:cn_glyph_row=16'h0300;
            12'd1281:cn_glyph_row=16'h0300;
            12'd1282:cn_glyph_row=16'h0200;
            12'd1283:cn_glyph_row=16'h3ffe;
            12'd1284:cn_glyph_row=16'h0200;
            12'd1285:cn_glyph_row=16'h0600;
            12'd1286:cn_glyph_row=16'h0400;
            12'd1287:cn_glyph_row=16'h0ffc;
            12'd1288:cn_glyph_row=16'h08c0;
            12'd1289:cn_glyph_row=16'h18c0;
            12'd1290:cn_glyph_row=16'h30c0;
            12'd1291:cn_glyph_row=16'h60c0;
            12'd1292:cn_glyph_row=16'h40c0;
            12'd1293:cn_glyph_row=16'h1ffe;
            12'd1296:cn_glyph_row=16'h0020;
            12'd1297:cn_glyph_row=16'h0bfc;
            12'd1298:cn_glyph_row=16'h1a04;
            12'd1299:cn_glyph_row=16'h1204;
            12'd1300:cn_glyph_row=16'h33fc;
            12'd1301:cn_glyph_row=16'h3200;
            12'd1302:cn_glyph_row=16'h53fe;
            12'd1303:cn_glyph_row=16'h5352;
            12'd1304:cn_glyph_row=16'h1352;
            12'd1305:cn_glyph_row=16'h17fe;
            12'd1306:cn_glyph_row=16'h1752;
            12'd1307:cn_glyph_row=16'h1b52;
            12'd1308:cn_glyph_row=16'h1352;
            12'd1309:cn_glyph_row=16'h1306;
            12'd1310:cn_glyph_row=16'h0304;
            12'd1312:cn_glyph_row=16'h0180;
            12'd1313:cn_glyph_row=16'h0100;
            12'd1314:cn_glyph_row=16'h0300;
            12'd1315:cn_glyph_row=16'h7ffe;
            12'd1316:cn_glyph_row=16'h0200;
            12'd1317:cn_glyph_row=16'h0600;
            12'd1318:cn_glyph_row=16'h0400;
            12'd1319:cn_glyph_row=16'h0ff8;
            12'd1320:cn_glyph_row=16'h1c08;
            12'd1321:cn_glyph_row=16'h3c08;
            12'd1322:cn_glyph_row=16'h6c08;
            12'd1323:cn_glyph_row=16'h4c08;
            12'd1324:cn_glyph_row=16'h0ff8;
            12'd1325:cn_glyph_row=16'h0ff8;
            12'd1326:cn_glyph_row=16'h0c08;
            12'd1329:cn_glyph_row=16'h3ff8;
            12'd1330:cn_glyph_row=16'h0008;
            12'd1331:cn_glyph_row=16'h0008;
            12'd1332:cn_glyph_row=16'h3008;
            12'd1333:cn_glyph_row=16'h3008;
            12'd1334:cn_glyph_row=16'h3ff8;
            12'd1335:cn_glyph_row=16'h3008;
            12'd1336:cn_glyph_row=16'h3000;
            12'd1337:cn_glyph_row=16'h3000;
            12'd1338:cn_glyph_row=16'h3000;
            12'd1339:cn_glyph_row=16'h3006;
            12'd1340:cn_glyph_row=16'h3006;
            12'd1341:cn_glyph_row=16'h1ffc;
            12'd1344:cn_glyph_row=16'h11fc;
            12'd1345:cn_glyph_row=16'h11fc;
            12'd1346:cn_glyph_row=16'h1104;
            12'd1347:cn_glyph_row=16'h7dfc;
            12'd1348:cn_glyph_row=16'h1104;
            12'd1349:cn_glyph_row=16'h11fc;
            12'd1350:cn_glyph_row=16'h1000;
            12'd1351:cn_glyph_row=16'h1bfe;
            12'd1352:cn_glyph_row=16'hf020;
            12'd1353:cn_glyph_row=16'h1120;
            12'd1354:cn_glyph_row=16'h113c;
            12'd1355:cn_glyph_row=16'h1320;
            12'd1356:cn_glyph_row=16'h12e0;
            12'd1357:cn_glyph_row=16'h767e;
            12'd1358:cn_glyph_row=16'h0400;
            12'd1360:cn_glyph_row=16'h0100;
            12'd1361:cn_glyph_row=16'h0180;
            12'd1363:cn_glyph_row=16'h7ffe;
            12'd1364:cn_glyph_row=16'h0c30;
            12'd1365:cn_glyph_row=16'h1818;
            12'd1366:cn_glyph_row=16'h302c;
            12'd1367:cn_glyph_row=16'h2420;
            12'd1368:cn_glyph_row=16'h0660;
            12'd1369:cn_glyph_row=16'h0240;
            12'd1370:cn_glyph_row=16'h0180;
            12'd1371:cn_glyph_row=16'h03c0;
            12'd1372:cn_glyph_row=16'h0e70;
            12'd1373:cn_glyph_row=16'h781e;
            12'd1376:cn_glyph_row=16'h1020;
            12'd1377:cn_glyph_row=16'h1820;
            12'd1378:cn_glyph_row=16'h0840;
            12'd1379:cn_glyph_row=16'h7f7e;
            12'd1380:cn_glyph_row=16'h104c;
            12'd1381:cn_glyph_row=16'h10cc;
            12'd1382:cn_glyph_row=16'h1ec8;
            12'd1383:cn_glyph_row=16'h1248;
            12'd1384:cn_glyph_row=16'h1228;
            12'd1385:cn_glyph_row=16'h1228;
            12'd1386:cn_glyph_row=16'h3230;
            12'd1387:cn_glyph_row=16'h2230;
            12'd1388:cn_glyph_row=16'h6268;
            12'd1389:cn_glyph_row=16'h4fc6;
            12'd1390:cn_glyph_row=16'h0002;
            12'd1393:cn_glyph_row=16'h7ffe;
            12'd1394:cn_glyph_row=16'h0100;
            12'd1395:cn_glyph_row=16'h0100;
            12'd1396:cn_glyph_row=16'h0100;
            12'd1397:cn_glyph_row=16'h0100;
            12'd1398:cn_glyph_row=16'h0160;
            12'd1399:cn_glyph_row=16'h0130;
            12'd1400:cn_glyph_row=16'h0118;
            12'd1401:cn_glyph_row=16'h010c;
            12'd1402:cn_glyph_row=16'h0100;
            12'd1403:cn_glyph_row=16'h0100;
            12'd1404:cn_glyph_row=16'h0100;
            12'd1405:cn_glyph_row=16'h0100;
            12'd1412:cn_glyph_row=16'h7ffe;
            12'd1413:cn_glyph_row=16'h7ffe;
            12'd1424:cn_glyph_row=16'h0080;
            12'd1425:cn_glyph_row=16'h7c8c;
            12'd1426:cn_glyph_row=16'h0488;
            12'd1427:cn_glyph_row=16'h0490;
            12'd1428:cn_glyph_row=16'h04b0;
            12'd1429:cn_glyph_row=16'h7c80;
            12'd1430:cn_glyph_row=16'h63fe;
            12'd1431:cn_glyph_row=16'h60a0;
            12'd1432:cn_glyph_row=16'h7c90;
            12'd1433:cn_glyph_row=16'h0490;
            12'd1434:cn_glyph_row=16'h0498;
            12'd1435:cn_glyph_row=16'h0488;
            12'd1436:cn_glyph_row=16'h0ce6;
            12'd1437:cn_glyph_row=16'h39c2;
            12'd1440:cn_glyph_row=16'h0820;
            12'd1441:cn_glyph_row=16'h0820;
            12'd1442:cn_glyph_row=16'h1820;
            12'd1443:cn_glyph_row=16'h1f20;
            12'd1444:cn_glyph_row=16'h1128;
            12'd1445:cn_glyph_row=16'h312c;
            12'd1446:cn_glyph_row=16'h3126;
            12'd1447:cn_glyph_row=16'h5b22;
            12'd1448:cn_glyph_row=16'h0a20;
            12'd1449:cn_glyph_row=16'h0e20;
            12'd1450:cn_glyph_row=16'h0620;
            12'd1451:cn_glyph_row=16'h0f20;
            12'd1452:cn_glyph_row=16'h19c0;
            12'd1453:cn_glyph_row=16'h607e;
            12'd1454:cn_glyph_row=16'h4000;
            12'd1456:cn_glyph_row=16'h01fe;
            12'd1457:cn_glyph_row=16'h7d26;
            12'd1458:cn_glyph_row=16'h1126;
            12'd1459:cn_glyph_row=16'h11fe;
            12'd1460:cn_glyph_row=16'h1126;
            12'd1461:cn_glyph_row=16'h7d26;
            12'd1462:cn_glyph_row=16'h11fe;
            12'd1463:cn_glyph_row=16'h1020;
            12'd1464:cn_glyph_row=16'h1020;
            12'd1465:cn_glyph_row=16'h13fe;
            12'd1466:cn_glyph_row=16'h1c20;
            12'd1467:cn_glyph_row=16'h6020;
            12'd1468:cn_glyph_row=16'h03fe;
            12'd1472:cn_glyph_row=16'h018c;
            12'd1473:cn_glyph_row=16'h1088;
            12'd1474:cn_glyph_row=16'h13fe;
            12'd1475:cn_glyph_row=16'h1222;
            12'd1476:cn_glyph_row=16'h12aa;
            12'd1477:cn_glyph_row=16'h7eaa;
            12'd1478:cn_glyph_row=16'h1222;
            12'd1479:cn_glyph_row=16'h13fe;
            12'd1480:cn_glyph_row=16'h1000;
            12'd1481:cn_glyph_row=16'h11fc;
            12'd1482:cn_glyph_row=16'h1d04;
            12'd1483:cn_glyph_row=16'h71fc;
            12'd1484:cn_glyph_row=16'h0104;
            12'd1485:cn_glyph_row=16'h01fc;
            12'd1486:cn_glyph_row=16'h0104;
            12'd1488:cn_glyph_row=16'h0c30;
            12'd1489:cn_glyph_row=16'h0420;
            12'd1490:cn_glyph_row=16'h0460;
            12'd1491:cn_glyph_row=16'h7ffe;
            12'd1493:cn_glyph_row=16'h0670;
            12'd1494:cn_glyph_row=16'h181c;
            12'd1495:cn_glyph_row=16'h7004;
            12'd1496:cn_glyph_row=16'h1ff8;
            12'd1497:cn_glyph_row=16'h1248;
            12'd1498:cn_glyph_row=16'h1248;
            12'd1499:cn_glyph_row=16'h1248;
            12'd1500:cn_glyph_row=16'h1248;
            12'd1501:cn_glyph_row=16'h7ffe;
            12'd1504:cn_glyph_row=16'h1020;
            12'd1505:cn_glyph_row=16'h1124;
            12'd1506:cn_glyph_row=16'h3dac;
            12'd1507:cn_glyph_row=16'h20a8;
            12'd1508:cn_glyph_row=16'h6020;
            12'd1509:cn_glyph_row=16'h7dfc;
            12'd1510:cn_glyph_row=16'h1184;
            12'd1511:cn_glyph_row=16'h11a4;
            12'd1512:cn_glyph_row=16'h7da4;
            12'd1513:cn_glyph_row=16'h11a4;
            12'd1514:cn_glyph_row=16'h11a4;
            12'd1515:cn_glyph_row=16'h1460;
            12'd1516:cn_glyph_row=16'h184c;
            12'd1517:cn_glyph_row=16'h1386;
            12'd1518:cn_glyph_row=16'h0100;
            12'd1520:cn_glyph_row=16'h0300;
            12'd1521:cn_glyph_row=16'h0300;
            12'd1522:cn_glyph_row=16'h1ff8;
            12'd1523:cn_glyph_row=16'h1ff8;
            12'd1524:cn_glyph_row=16'h1008;
            12'd1525:cn_glyph_row=16'h1008;
            12'd1526:cn_glyph_row=16'h1ff8;
            12'd1527:cn_glyph_row=16'h1008;
            12'd1528:cn_glyph_row=16'h1008;
            12'd1529:cn_glyph_row=16'h1ff8;
            12'd1530:cn_glyph_row=16'h1008;
            12'd1531:cn_glyph_row=16'h1008;
            12'd1532:cn_glyph_row=16'h1ff8;
            12'd1533:cn_glyph_row=16'h1008;
            12'd1536:cn_glyph_row=16'h01fc;
            12'd1537:cn_glyph_row=16'h7904;
            12'd1538:cn_glyph_row=16'h49fc;
            12'd1539:cn_glyph_row=16'h4904;
            12'd1540:cn_glyph_row=16'h49fc;
            12'd1541:cn_glyph_row=16'h7bfc;
            12'd1542:cn_glyph_row=16'h4898;
            12'd1543:cn_glyph_row=16'h4bfe;
            12'd1544:cn_glyph_row=16'h48d8;
            12'd1545:cn_glyph_row=16'h49ac;
            12'd1546:cn_glyph_row=16'h7eae;
            12'd1547:cn_glyph_row=16'h48f8;
            12'd1548:cn_glyph_row=16'h49ac;
            12'd1549:cn_glyph_row=16'h0262;
            12'd1550:cn_glyph_row=16'h0040;
            12'd1552:cn_glyph_row=16'h0180;
            12'd1553:cn_glyph_row=16'h0180;
            12'd1554:cn_glyph_row=16'h118c;
            12'd1555:cn_glyph_row=16'h1998;
            12'd1556:cn_glyph_row=16'h0db0;
            12'd1557:cn_glyph_row=16'h0180;
            12'd1558:cn_glyph_row=16'h7ffe;
            12'd1559:cn_glyph_row=16'h0240;
            12'd1560:cn_glyph_row=16'h0240;
            12'd1561:cn_glyph_row=16'h0640;
            12'd1562:cn_glyph_row=16'h0440;
            12'd1563:cn_glyph_row=16'h0c42;
            12'd1564:cn_glyph_row=16'h1846;
            12'd1565:cn_glyph_row=16'h707c;
            12'd1568:cn_glyph_row=16'h0180;
            12'd1569:cn_glyph_row=16'h0180;
            12'd1570:cn_glyph_row=16'h0180;
            12'd1571:cn_glyph_row=16'h3ffc;
            12'd1572:cn_glyph_row=16'h2184;
            12'd1573:cn_glyph_row=16'h2184;
            12'd1574:cn_glyph_row=16'h2184;
            12'd1575:cn_glyph_row=16'h2184;
            12'd1576:cn_glyph_row=16'h3ffc;
            12'd1577:cn_glyph_row=16'h2184;
            12'd1578:cn_glyph_row=16'h0180;
            12'd1579:cn_glyph_row=16'h0180;
            12'd1580:cn_glyph_row=16'h0180;
            12'd1581:cn_glyph_row=16'h0180;
            12'd1582:cn_glyph_row=16'h0180;
            12'd1585:cn_glyph_row=16'h1ff8;
            12'd1586:cn_glyph_row=16'h0100;
            12'd1587:cn_glyph_row=16'h0100;
            12'd1588:cn_glyph_row=16'h0100;
            12'd1589:cn_glyph_row=16'h0100;
            12'd1590:cn_glyph_row=16'h7ffe;
            12'd1591:cn_glyph_row=16'h0340;
            12'd1592:cn_glyph_row=16'h0240;
            12'd1593:cn_glyph_row=16'h0240;
            12'd1594:cn_glyph_row=16'h0640;
            12'd1595:cn_glyph_row=16'h0c42;
            12'd1596:cn_glyph_row=16'h1846;
            12'd1597:cn_glyph_row=16'h707c;
            12'd1600:cn_glyph_row=16'h1ffc;
            12'd1601:cn_glyph_row=16'h118c;
            12'd1602:cn_glyph_row=16'h118c;
            12'd1603:cn_glyph_row=16'h1ffc;
            12'd1604:cn_glyph_row=16'h118c;
            12'd1605:cn_glyph_row=16'h118c;
            12'd1606:cn_glyph_row=16'h118c;
            12'd1607:cn_glyph_row=16'h1ffc;
            12'd1608:cn_glyph_row=16'h318c;
            12'd1609:cn_glyph_row=16'h318c;
            12'd1610:cn_glyph_row=16'h218c;
            12'd1611:cn_glyph_row=16'h218c;
            12'd1612:cn_glyph_row=16'h6198;
            12'd1616:cn_glyph_row=16'h0300;
            12'd1617:cn_glyph_row=16'h0180;
            12'd1618:cn_glyph_row=16'h7ffe;
            12'd1619:cn_glyph_row=16'h6006;
            12'd1620:cn_glyph_row=16'h6006;
            12'd1621:cn_glyph_row=16'h0ff0;
            12'd1623:cn_glyph_row=16'h7ffe;
            12'd1624:cn_glyph_row=16'h0640;
            12'd1625:cn_glyph_row=16'h0440;
            12'd1626:cn_glyph_row=16'h0440;
            12'd1627:cn_glyph_row=16'h0c40;
            12'd1628:cn_glyph_row=16'h1846;
            12'd1629:cn_glyph_row=16'h707c;
            12'd1632:cn_glyph_row=16'h0840;
            12'd1633:cn_glyph_row=16'h1860;
            12'd1634:cn_glyph_row=16'h17fe;
            12'd1635:cn_glyph_row=16'h1000;
            12'd1636:cn_glyph_row=16'h33fc;
            12'd1637:cn_glyph_row=16'h3000;
            12'd1638:cn_glyph_row=16'h5000;
            12'd1639:cn_glyph_row=16'h53fc;
            12'd1640:cn_glyph_row=16'h1000;
            12'd1641:cn_glyph_row=16'h13fc;
            12'd1642:cn_glyph_row=16'h1304;
            12'd1643:cn_glyph_row=16'h1304;
            12'd1644:cn_glyph_row=16'h13fc;
            12'd1645:cn_glyph_row=16'h1304;
            12'd1646:cn_glyph_row=16'h1000;
            12'd1648:cn_glyph_row=16'h0300;
            12'd1649:cn_glyph_row=16'h0200;
            12'd1650:cn_glyph_row=16'h1ff8;
            12'd1651:cn_glyph_row=16'h1008;
            12'd1652:cn_glyph_row=16'h1ff8;
            12'd1653:cn_glyph_row=16'h1008;
            12'd1654:cn_glyph_row=16'h1ff8;
            12'd1655:cn_glyph_row=16'h1008;
            12'd1656:cn_glyph_row=16'h1ff8;
            12'd1657:cn_glyph_row=16'h0080;
            12'd1658:cn_glyph_row=16'h248c;
            12'd1659:cn_glyph_row=16'h2486;
            12'd1660:cn_glyph_row=16'h4412;
            12'd1661:cn_glyph_row=16'h07f0;
            12'd1664:cn_glyph_row=16'h1008;
            12'd1665:cn_glyph_row=16'h11fc;
            12'd1666:cn_glyph_row=16'h1130;
            12'd1667:cn_glyph_row=16'h2530;
            12'd1668:cn_glyph_row=16'h6530;
            12'd1669:cn_glyph_row=16'h7930;
            12'd1670:cn_glyph_row=16'h19fe;
            12'd1671:cn_glyph_row=16'h1130;
            12'd1672:cn_glyph_row=16'h3d10;
            12'd1673:cn_glyph_row=16'h3110;
            12'd1674:cn_glyph_row=16'h0110;
            12'd1675:cn_glyph_row=16'h1d5a;
            12'd1676:cn_glyph_row=16'h618a;
            12'd1677:cn_glyph_row=16'h010e;
            12'd1680:cn_glyph_row=16'h3ffe;
            12'd1681:cn_glyph_row=16'h0240;
            12'd1682:cn_glyph_row=16'h3ffc;
            12'd1683:cn_glyph_row=16'h2244;
            12'd1684:cn_glyph_row=16'h3ffc;
            12'd1685:cn_glyph_row=16'h09fc;
            12'd1686:cn_glyph_row=16'h3600;
            12'd1687:cn_glyph_row=16'h4bfc;
            12'd1688:cn_glyph_row=16'h1bfc;
            12'd1689:cn_glyph_row=16'h33fc;
            12'd1690:cn_glyph_row=16'h5080;
            12'd1691:cn_glyph_row=16'h13f8;
            12'd1692:cn_glyph_row=16'h12d0;
            12'd1693:cn_glyph_row=16'h11f8;
            12'd1694:cn_glyph_row=16'h1206;
            12'd1696:cn_glyph_row=16'h0420;
            12'd1697:cn_glyph_row=16'h0640;
            12'd1698:cn_glyph_row=16'h3ffc;
            12'd1699:cn_glyph_row=16'h0180;
            12'd1700:cn_glyph_row=16'h0180;
            12'd1701:cn_glyph_row=16'h1ff8;
            12'd1702:cn_glyph_row=16'h0180;
            12'd1703:cn_glyph_row=16'h7ffe;
            12'd1705:cn_glyph_row=16'h3ff8;
            12'd1706:cn_glyph_row=16'h3248;
            12'd1707:cn_glyph_row=16'h3248;
            12'd1708:cn_glyph_row=16'h3248;
            12'd1709:cn_glyph_row=16'hfffe;
            12'd1712:cn_glyph_row=16'h1000;
            12'd1713:cn_glyph_row=16'h19fc;
            12'd1714:cn_glyph_row=16'h0804;
            12'd1715:cn_glyph_row=16'h6004;
            12'd1716:cn_glyph_row=16'h67e4;
            12'd1717:cn_glyph_row=16'h6424;
            12'd1718:cn_glyph_row=16'h6424;
            12'd1719:cn_glyph_row=16'h67e4;
            12'd1720:cn_glyph_row=16'h6424;
            12'd1721:cn_glyph_row=16'h6424;
            12'd1722:cn_glyph_row=16'h67e4;
            12'd1723:cn_glyph_row=16'h6004;
            12'd1724:cn_glyph_row=16'h6004;
            12'd1725:cn_glyph_row=16'h600c;
            12'd1728:cn_glyph_row=16'h0028;
            12'd1729:cn_glyph_row=16'h2024;
            12'd1730:cn_glyph_row=16'h1024;
            12'd1731:cn_glyph_row=16'h07fe;
            12'd1732:cn_glyph_row=16'h0020;
            12'd1733:cn_glyph_row=16'h7020;
            12'd1734:cn_glyph_row=16'h13a0;
            12'd1735:cn_glyph_row=16'h13a0;
            12'd1736:cn_glyph_row=16'h1130;
            12'd1737:cn_glyph_row=16'h1110;
            12'd1738:cn_glyph_row=16'h1510;
            12'd1739:cn_glyph_row=16'h19da;
            12'd1740:cn_glyph_row=16'h378a;
            12'd1741:cn_glyph_row=16'h000e;
            12'd1744:cn_glyph_row=16'h3ffc;
            12'd1745:cn_glyph_row=16'h0620;
            12'd1746:cn_glyph_row=16'h0620;
            12'd1747:cn_glyph_row=16'h0620;
            12'd1748:cn_glyph_row=16'h0620;
            12'd1749:cn_glyph_row=16'h7ffe;
            12'd1750:cn_glyph_row=16'h7ffe;
            12'd1751:cn_glyph_row=16'h0620;
            12'd1752:cn_glyph_row=16'h0420;
            12'd1753:cn_glyph_row=16'h0420;
            12'd1754:cn_glyph_row=16'h0c20;
            12'd1755:cn_glyph_row=16'h1820;
            12'd1756:cn_glyph_row=16'h7020;
            12'd1760:cn_glyph_row=16'h0180;
            12'd1761:cn_glyph_row=16'h0080;
            12'd1762:cn_glyph_row=16'h1ffc;
            12'd1763:cn_glyph_row=16'h100c;
            12'd1764:cn_glyph_row=16'h100c;
            12'd1765:cn_glyph_row=16'h1ffc;
            12'd1766:cn_glyph_row=16'h1ffc;
            12'd1767:cn_glyph_row=16'h1000;
            12'd1768:cn_glyph_row=16'h17fc;
            12'd1769:cn_glyph_row=16'h140c;
            12'd1770:cn_glyph_row=16'h340c;
            12'd1771:cn_glyph_row=16'h240c;
            12'd1772:cn_glyph_row=16'h67fc;
            12'd1773:cn_glyph_row=16'h440c;
            12'd1774:cn_glyph_row=16'h040c;
            12'd1776:cn_glyph_row=16'h0018;
            12'd1777:cn_glyph_row=16'h3018;
            12'd1778:cn_glyph_row=16'h1018;
            12'd1779:cn_glyph_row=16'h1bfe;
            12'd1780:cn_glyph_row=16'h0018;
            12'd1781:cn_glyph_row=16'h0118;
            12'd1782:cn_glyph_row=16'h7118;
            12'd1783:cn_glyph_row=16'h1198;
            12'd1784:cn_glyph_row=16'h1098;
            12'd1785:cn_glyph_row=16'h1018;
            12'd1786:cn_glyph_row=16'h1010;
            12'd1787:cn_glyph_row=16'h1070;
            12'd1788:cn_glyph_row=16'h3c00;
            12'd1789:cn_glyph_row=16'h67fe;
            12'd1792:cn_glyph_row=16'h0040;
            12'd1793:cn_glyph_row=16'h0020;
            12'd1794:cn_glyph_row=16'h7bfc;
            12'd1795:cn_glyph_row=16'h4888;
            12'd1796:cn_glyph_row=16'h4888;
            12'd1797:cn_glyph_row=16'h4890;
            12'd1798:cn_glyph_row=16'h7bfe;
            12'd1799:cn_glyph_row=16'h4800;
            12'd1800:cn_glyph_row=16'h49fc;
            12'd1801:cn_glyph_row=16'h4904;
            12'd1802:cn_glyph_row=16'h49fc;
            12'd1803:cn_glyph_row=16'h7904;
            12'd1804:cn_glyph_row=16'h4904;
            12'd1805:cn_glyph_row=16'h01fc;
            12'd1806:cn_glyph_row=16'h0100;
            12'd1808:cn_glyph_row=16'h0050;
            12'd1809:cn_glyph_row=16'h0058;
            12'd1810:cn_glyph_row=16'h0048;
            12'd1811:cn_glyph_row=16'h7ffe;
            12'd1812:cn_glyph_row=16'h0040;
            12'd1813:cn_glyph_row=16'h3e40;
            12'd1814:cn_glyph_row=16'h224c;
            12'd1815:cn_glyph_row=16'h2248;
            12'd1816:cn_glyph_row=16'h2258;
            12'd1817:cn_glyph_row=16'h3e30;
            12'd1818:cn_glyph_row=16'h0030;
            12'd1819:cn_glyph_row=16'h0f70;
            12'd1820:cn_glyph_row=16'h70d2;
            12'd1821:cn_glyph_row=16'h038e;
            12'd1822:cn_glyph_row=16'h0004;
            12'd1824:cn_glyph_row=16'h0420;
            12'd1825:cn_glyph_row=16'h0420;
            12'd1826:cn_glyph_row=16'h0660;
            12'd1827:cn_glyph_row=16'h3ffc;
            12'd1828:cn_glyph_row=16'h3ffc;
            12'd1829:cn_glyph_row=16'h0180;
            12'd1830:cn_glyph_row=16'h0180;
            12'd1831:cn_glyph_row=16'h0180;
            12'd1832:cn_glyph_row=16'h7ffe;
            12'd1833:cn_glyph_row=16'h0180;
            12'd1834:cn_glyph_row=16'h0340;
            12'd1835:cn_glyph_row=16'h0670;
            12'd1836:cn_glyph_row=16'h0c1c;
            12'd1837:cn_glyph_row=16'h700e;
            12'd1840:cn_glyph_row=16'h0860;
            12'd1841:cn_glyph_row=16'h0860;
            12'd1842:cn_glyph_row=16'h0860;
            12'd1843:cn_glyph_row=16'h0060;
            12'd1844:cn_glyph_row=16'h7c68;
            12'd1845:cn_glyph_row=16'h0c68;
            12'd1846:cn_glyph_row=16'h096c;
            12'd1847:cn_glyph_row=16'h1a66;
            12'd1848:cn_glyph_row=16'h2e62;
            12'd1849:cn_glyph_row=16'h4b60;
            12'd1850:cn_glyph_row=16'h0860;
            12'd1851:cn_glyph_row=16'h0860;
            12'd1852:cn_glyph_row=16'h0860;
            12'd1853:cn_glyph_row=16'h0860;
            12'd1854:cn_glyph_row=16'h0860;
            12'd1857:cn_glyph_row=16'h1ffc;
            12'd1858:cn_glyph_row=16'h1000;
            12'd1859:cn_glyph_row=16'h1000;
            12'd1860:cn_glyph_row=16'h1000;
            12'd1861:cn_glyph_row=16'h1ff8;
            12'd1862:cn_glyph_row=16'h1618;
            12'd1863:cn_glyph_row=16'h1210;
            12'd1864:cn_glyph_row=16'h1330;
            12'd1865:cn_glyph_row=16'h1120;
            12'd1866:cn_glyph_row=16'h31e0;
            12'd1867:cn_glyph_row=16'h20c0;
            12'd1868:cn_glyph_row=16'h63f0;
            12'd1869:cn_glyph_row=16'h5e1c;
            12'd1872:cn_glyph_row=16'h01fc;
            12'd1873:cn_glyph_row=16'h7d04;
            12'd1874:cn_glyph_row=16'h0d04;
            12'd1875:cn_glyph_row=16'h0dfc;
            12'd1876:cn_glyph_row=16'h7c20;
            12'd1877:cn_glyph_row=16'h6020;
            12'd1878:cn_glyph_row=16'h61fc;
            12'd1879:cn_glyph_row=16'h7924;
            12'd1880:cn_glyph_row=16'h0924;
            12'd1881:cn_glyph_row=16'h09fc;
            12'd1882:cn_glyph_row=16'h0920;
            12'd1883:cn_glyph_row=16'h0824;
            12'd1884:cn_glyph_row=16'h083e;
            12'd1885:cn_glyph_row=16'h3bc2;
            12'd1888:cn_glyph_row=16'h0008;
            12'd1889:cn_glyph_row=16'h0008;
            12'd1890:cn_glyph_row=16'h7e08;
            12'd1891:cn_glyph_row=16'h0208;
            12'd1892:cn_glyph_row=16'h03fe;
            12'd1893:cn_glyph_row=16'h2408;
            12'd1894:cn_glyph_row=16'h3488;
            12'd1895:cn_glyph_row=16'h1c88;
            12'd1896:cn_glyph_row=16'h0c48;
            12'd1897:cn_glyph_row=16'h0c48;
            12'd1898:cn_glyph_row=16'h1608;
            12'd1899:cn_glyph_row=16'h3208;
            12'd1900:cn_glyph_row=16'h6008;
            12'd1901:cn_glyph_row=16'h4038;
            12'd1904:cn_glyph_row=16'h1000;
            12'd1905:cn_glyph_row=16'h11fc;
            12'd1906:cn_glyph_row=16'h1000;
            12'd1907:cn_glyph_row=16'h7c00;
            12'd1908:cn_glyph_row=16'h7c00;
            12'd1909:cn_glyph_row=16'h13fe;
            12'd1910:cn_glyph_row=16'h3820;
            12'd1911:cn_glyph_row=16'h3420;
            12'd1912:cn_glyph_row=16'h37ac;
            12'd1913:cn_glyph_row=16'h51a4;
            12'd1914:cn_glyph_row=16'h5126;
            12'd1915:cn_glyph_row=16'h1322;
            12'd1916:cn_glyph_row=16'h1220;
            12'd1917:cn_glyph_row=16'h10e0;
            12'd1920:cn_glyph_row=16'h0820;
            12'd1921:cn_glyph_row=16'h1f7e;
            12'd1922:cn_glyph_row=16'h3448;
            12'd1923:cn_glyph_row=16'h6488;
            12'd1924:cn_glyph_row=16'h0180;
            12'd1925:cn_glyph_row=16'h03c0;
            12'd1926:cn_glyph_row=16'h0e70;
            12'd1927:cn_glyph_row=16'h381e;
            12'd1928:cn_glyph_row=16'h67f2;
            12'd1929:cn_glyph_row=16'h0010;
            12'd1930:cn_glyph_row=16'h0910;
            12'd1931:cn_glyph_row=16'h09b0;
            12'd1932:cn_glyph_row=16'h0020;
            12'd1933:cn_glyph_row=16'h3ffc;
            default:cn_glyph_row=0;
        endcase end
    endfunction
    // CHINESE_FONT_END
    // presentation and board telemetry use the same registered states.
    wire [2:0] ready_classes={2'd0,bottle_enabled[0]}+{2'd0,bottle_enabled[1]}+
        {2'd0,bottle_enabled[2]}+{2'd0,bottle_enabled[3]}+{2'd0,bottle_enabled[4]};
    wire learning_mode=group_id==0 && (ui_page==3 || ui_page==4);
    wire bottle_page=group_id==0 && ui_page!=6;
    wire calibration_in_flight=calibration_changed || (|calibration_pipe);
    reg [2:0] announced_class;
    reg [11:0] drink_events;
    reg [7:0] last_record_counter;
    reg drink_event_toggle,learn_event_toggle;
    function [11:0] bcd3_inc;
        input [11:0] v;
        begin
            if(v==12'h999)bcd3_inc=v;
            else if(v[3:0]!=9)bcd3_inc=v+1'b1;
            else if(v[7:4]!=9)bcd3_inc={v[11:4]+8'd1,4'd0};
            else bcd3_inc={v[11:8]+4'd1,8'd0};
        end
    endfunction
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n)begin
            announced_class<=0;drink_events<=0;last_record_counter<=0;
            drink_event_toggle<=0;learn_event_toggle<=0;
        end else begin
            if(bottle_record_counter!=last_record_counter)begin
                last_record_counter<=bottle_record_counter;learn_event_toggle<=~learn_event_toggle;
            end
            if(calibration_in_flight || bottle_status==1)announced_class<=0;
            else if(bottle_confirm && group_id==0 && ui_page==0 && bottle_status==3 && bottle_id!=0 && bottle_id!=announced_class)begin
                announced_class<=bottle_id;drink_events<=bcd3_inc(drink_events);
                drink_event_toggle<=~drink_event_toggle;
            end
        end
    end
    reg [31:0] board_digits;
    reg [3:0] score_h,score_t,score_u,led_flags;
    wire [1:0] board_view=ui_page==2 ? (bottle_enabled[selected_class] ? 2'd3:2'd0):bottle_session_count;
    wire notice_error=write_blocked || cal_timeout || (learning_mode && bottle_learn_error);
    always @(*)begin
        score_h=bottle_score>=100 ? 1:0;
        score_t=bottle_score>=100 ? 0:bottle_score/10;
        score_u=bottle_score>=100 ? 0:bottle_score%10;
        board_digits=32'hffffffff;
        if(group_id==1)board_digits=target_valid ? {x_digits,y_digits}:motion ? {motion_x_digits,motion_y_digits}:32'd0;
        else if(group_id==2)board_digits={4'd3,1'b0,effect_mode,display_frames};
        else if(ui_page==2 || ui_page==3 || ui_page==4)begin
            board_digits={ui_page==4 ? 4'd12:4'd11,1'b0,ui_page==4 ? 3'd0:selected_class+3'd1,
                4'd10,2'd0,board_view,4'd10,4'd0,ui_page==2 ? 4'd0:bottle_sample_progress,4'd10};
        end else board_digits={4'd1,1'b0,bottle_id,score_h,score_t,score_u,drink_events};
        led_flags={((group_id==0 && ui_page==0 && bottle_status==3) || (demo_mode && target_valid)),
            bottle_recording,(awb_locked && background_ready && (|bottle_enabled)),1'b0};
        board_status={15'd0,notice_error,learn_event_toggle,drink_event_toggle,
            (demo_mode && alert),1'b0,led_flags,8'd0,board_digits};
    end
    reg [7:0] edge_display,diag_gray,glyph_char;
    reg [4:0] glyph_bits;
    reg [11:0] tx,ty,cn_x,cn_y;
    reg [4:0] text_col;
    reg [3:0] text_row,digit;
    reg [255:0] text_label;
    reg [5:0] cn_phrase,state_phrase;
    // Register slowly changing OSD state before the two font lookups. Pixel
    // coordinates and all seven video/sync clocks retain their original timing.
    reg [5:0] cn_row0,cn_row1,cn_row2,cn_row3;
    reg [5:0] cn_header_q,cn_row0_q,cn_row1_q,cn_row2_q,cn_row3_q;
    reg [127:0] cn_header_chars,cn_row0_chars,cn_row1_chars,cn_row2_chars,cn_row3_chars;
    reg [127:0] cn_chars;
    integer cn_slot;
    // Decode complete text lines away from the coordinate-to-pixel path.
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            cn_header_chars<={128{1'b1}};cn_row0_chars<={128{1'b1}};
            cn_row1_chars<={128{1'b1}};cn_row2_chars<={128{1'b1}};cn_row3_chars<={128{1'b1}};
        end else for(cn_slot=0;cn_slot<16;cn_slot=cn_slot+1)begin
            cn_header_chars[cn_slot*8+:8]<=cn_phrase_char(cn_header_q,cn_slot);
            cn_row0_chars[cn_slot*8+:8]<=cn_phrase_char(cn_row0_q,cn_slot);
            cn_row1_chars[cn_slot*8+:8]<=cn_phrase_char(cn_row1_q,cn_slot);
            cn_row2_chars[cn_slot*8+:8]<=cn_phrase_char(cn_row2_q,cn_slot);
            cn_row3_chars[cn_slot*8+:8]<=cn_phrase_char(cn_row3_q,cn_slot);
        end
    end

    always @(*)begin
        case(bottle_status)
            1:state_phrase=17;2:state_phrase=18;3:state_phrase=19;4:state_phrase=20;
            5:state_phrase=15;6:state_phrase=16;7:state_phrase=39;default:state_phrase=14;
        endcase
        if(group_id==0 && ui_page==0 && bottle_status!=5 && bottle_status!=6 && bottle_status!=7)begin
            if(identify_busy)case(identify_reason)
                1:state_phrase=52;2:state_phrase=53;3:state_phrase=54;5:state_phrase=55;default:state_phrase=50;
            endcase
            else if(bottle_status==2)state_phrase=51;
            else if(bottle_status!=3 && bottle_status!=1)state_phrase=49;
        end
        if(learning_mode)begin
            if(bottle_recording)state_phrase=20;
            else if(bottle_learn_error)case(bottle_learn_reason)
                1:state_phrase=15;2:state_phrase=16;3:state_phrase=54;4:state_phrase=21;6:state_phrase=52;7:state_phrase=53;default:state_phrase=45;
            endcase
            else state_phrase=bottle_session_count==3 ? 30:33;
        end
        if(write_blocked)state_phrase=22;
        if(cal_timeout)state_phrase=43;

        cn_row0=63;cn_row1=63;cn_row2=63;cn_row3=63;
        if(group_id==2)cn_row0=34;
        else if(group_id==0)begin
            case(ui_page)
                0:cn_row0=bottle_id!=0 ? 7+bottle_id:state_phrase;
                1:cn_row0=3+menu_item;
                2,3:cn_row0=8+selected_class;
                4:cn_row0=5;
                5:cn_row0=awb_locked ? 23:6;
                6:cn_row0=7;
                7:cn_row0=44;
            endcase
            case(ui_page)
                0:cn_row1=state_phrase;
                1:cn_row1=25;
                2:cn_row1=bottle_enabled[selected_class] ? 40:13;
                3,4:cn_row1=state_phrase;
                5:cn_row1=write_blocked || !switch_flags[3] ? 46:
                    cal_timeout ? 47:((|bottle_enabled)||background_ready) ? 24:42;
                7:cn_row1=42;
            endcase
            if(ui_page==3)cn_row2=bottle_session_count==3 ? 30:27+bottle_session_count;
            else if(ui_page==0)cn_row2=49;
            else if(ui_page==5)cn_row2=write_blocked || !switch_flags[3] ? 48:25;
            if(ui_page==5)cn_row3=26;
            else if(ui_page==0)cn_row3=switch_flags[2] ? 36:ae_hold_active ? 37:38;
        end
    end
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin cn_header_q<=63;cn_row0_q<=63;cn_row1_q<=63;cn_row2_q<=63;cn_row3_q<=63;end
        else begin
            cn_header_q<={4'd0,group_id};cn_row0_q<=cn_row0;cn_row1_q<=cn_row1;
            cn_row2_q<=cn_row2;cn_row3_q<=cn_row3;
        end
    end

    reg [15:0] cn_bits;
    reg [23:0] roi_color;
    integer diag_k;
    always @(*)begin
        edge_display=clean_edges;
        diag_gray=0;
        for(diag_k=0;diag_k<16;diag_k=diag_k+1)if(view_x>=diag_k*80)diag_gray=diag_k*17;
        if(group_id==2)begin
            case(effect_mode)
                1:effect={view_gray,view_gray,view_gray};2:effect={edge_display,edge_display,edge_display};
                3:effect=view_cartoon;4:effect={view_median,view_median,view_median};
                5:effect={view_equalized,view_equalized,view_equalized};6:effect={adaptive_binary,adaptive_binary,adaptive_binary};default:effect=view_rgb;
            endcase
        end else effect=view_rgb;
        if(group_id==0 && ui_page==6)begin
            effect=24'h303030;
            if(view_y>=200 && view_y<432)begin
                if(view_x<160)effect=24'hffffff;else if(view_x<320)effect=24'hffff00;
                else if(view_x<480)effect=24'h00ffff;else if(view_x<640)effect=24'h00ff00;
                else if(view_x<800)effect=24'hff00ff;else if(view_x<960)effect=24'hff0000;
                else if(view_x<1120)effect=24'h0000ff;else effect=0;
            end else if(view_y>=432)effect={diag_gray,diag_gray,diag_gray};
        end
        pixel=view_de ? effect:24'd0;
        if(view_de && demo_mode)begin
            if(motion && view_x>=motion_box_x0 && view_x<=motion_box_x1 && view_y>=motion_box_y0 && view_y<=motion_box_y1 &&
              (view_x==motion_box_x0 || view_x==motion_box_x1 || view_y==motion_box_y0 || view_y==motion_box_y1))pixel=24'hffc000;
            if(target_valid)begin
                if(tracking_live && view_x>=box_min_x && view_x<=box_max_x && view_y>=box_min_y && view_y<=box_max_y &&
                  (view_x<=box_min_x+1 || view_x+1>=box_max_x || view_y<=box_min_y+1 || view_y+1>=box_max_y))pixel=24'h00ff40;
                if((view_x==target_x && view_y+12'd12>=target_y && view_y<=target_y+12'd12) ||
                  (view_y==target_y && view_x+12'd12>=target_x && view_x<=target_x+12'd12))pixel=tracking_live ? 24'h00ff40:24'hffb000;
            end
            if(alert && view_x>=352 && view_y<6)pixel=24'hff2030;
        end
        roi_color=bottle_status==3 ? 24'h00ff40:bottle_status==2 ? 24'hffb000:24'h00bfff;
        if(view_de && group_id==0 && (ui_page==0 || ui_page==3 || ui_page==4) &&
          view_x>=512 && view_x<768 && view_y>=104 && view_y<616 &&
          (view_x<514 || view_x>=766 || view_y<106 || view_y>=614))pixel=roi_color;
        if(group_id==0 && (ui_page==0 || ui_page==3) && view_de &&
           view_x>=544 && view_x<736 && view_y>=168 && view_y<552 &&
           (view_x==544 || view_x==735 || view_y==168 || view_y==551))pixel=24'hffff40;
        // Show the exact calibration ROI; the bottle placement ROI differs.
        if(view_de && group_id==0 && (ui_page==5 || ui_page==7) &&
          view_x>=320 && view_x<960 && view_y>=180 && view_y<540 &&
          (view_x<322 || view_x>=958 || view_y<182 || view_y>=538))pixel=24'hffffff;
        // Compact ASCII key hints and numeric diagnostics; no panel background.
        tx=view_x-176;ty=view_y-48;text_col=tx[8:4];text_row=ty[7:4];
        text_label=0;glyph_char=" ";digit=0;glyph_bits=0;
        if(view_de && view_x>=176 && view_x<688 && view_y>=48 && view_y<184)begin
            case(text_row)
                0:text_label="V1035                           ";
                1:text_label="KEY1 GROUP  KEY2 SELECT         ";
                2:text_label="KEY3 OK     KEY4 BACK           ";
                3:begin
                    text_label="SW2 DETAIL   AUTO   WRITE      ";
                    case(text_col)
                        10:glyph_char="0"+switch_flags[1];17:glyph_char="0"+switch_flags[2];
                        25:glyph_char="0"+switch_flags[3];
                    endcase
                end
                4:if(demo_mode)begin
                    text_label=target_valid ? "RED TRACK LOCKED                ":"RED TRACK LOST                  ";
                end else begin
                    text_label=switch_flags[2] ? "AE AUTO   SW3=1                 ":
                        ae_hold_active ? "AE HOLD   SW3=0                 ":"AE WAIT   FINISH CAMERA WRITE   ";
                end
                5:if(demo_mode)begin
                    text_label="X      Y                        ";
                    case(text_col)
                        2:digit=x_digits[15:12];3:digit=x_digits[11:8];4:digit=x_digits[7:4];5:digit=x_digits[3:0];
                        9:digit=y_digits[15:12];10:digit=y_digits[11:8];11:digit=y_digits[7:4];12:digit=y_digits[3:0];
                    endcase
                    if(text_col>=2 && text_col<=5 || text_col>=9 && text_col<=12)glyph_char="0"+digit;
                end else if(switch_flags[1] || ui_page==6)begin
                    if(group_id==0 && ui_page==0)begin
                        text_label="BG HEX       EDGE HEX           ";
                        if(text_col>=7 && text_col<=10)digit=(bottle_bg_distance>>((10-text_col)*4))&4'hf;
                        if(text_col>=22 && text_col<=24)digit=(bottle_edges>>((24-text_col)*4))&4'hf;
                        if(text_col>=7 && text_col<=10 || text_col>=22 && text_col<=24)
                            glyph_char=digit<10 ? "0"+digit:"A"+digit-10;
                    end else begin
                        text_label="DDR AGE     FR                  ";
                        if(text_col==8 && age_digits_valid)glyph_char="0"+age_digits[11:8];
                        if(text_col==9 && age_digits_valid)glyph_char="0"+age_digits[7:4];
                        if(text_col==10 && age_digits_valid)glyph_char="0"+age_digits[3:0];
                    end
                end
                6:if(demo_mode)begin
                    text_label=motion ? "MOTION YES  EVENTS              ":"MOTION NO   EVENTS              ";
                    if(text_col>=19 && text_col<=22)glyph_char="0"+((motion_events >> ((22-text_col)*4)) & 4'hf);
                end else if(switch_flags[1] || ui_page==6)begin
                    if(group_id==0 && ui_page==0)begin
                        text_label="BEST HEX      STR MIN           ";
                        if(text_col>=9 && text_col<=12)digit=(bottle_best_distance>>((12-text_col)*4))&4'hf;
                        if(text_col>=23 && text_col<=26)digit=(bottle_structure>>((26-text_col)*4))&4'hf;
                        if(text_col>=9 && text_col<=12 || text_col>=23 && text_col<=26)
                            glyph_char=digit<10 ? "0"+digit:"A"+digit-10;
                    end else begin
                        text_label="HDMI FRAMES                     ";
                        if(text_col>=12 && text_col<=17)glyph_char="0"+((display_frames >> ((17-text_col)*4)) & 4'hf);
                    end
                end
                7:if(demo_mode)begin
                    text_label="MX       MY                     ";
                    case(text_col)
                        3:digit=motion_x_digits[15:12];4:digit=motion_x_digits[11:8];5:digit=motion_x_digits[7:4];6:digit=motion_x_digits[3:0];
                        12:digit=motion_y_digits[15:12];13:digit=motion_y_digits[11:8];14:digit=motion_y_digits[7:4];15:digit=motion_y_digits[3:0];
                    endcase
                    if(text_col>=3 && text_col<=6 || text_col>=12 && text_col<=15)glyph_char="0"+digit;
                end else if(switch_flags[1] || ui_page==6)begin
                    if(group_id==0 && ui_page==0)begin
                        text_label="COLOR HEX     GAP HEX           ";
                        if(text_col>=10 && text_col<=13)digit=(bottle_color>>((13-text_col)*4))&4'hf;
                        if(text_col>=22 && text_col<=25)digit=(bottle_margin>>((25-text_col)*4))&4'hf;
                        if(text_col>=10 && text_col<=13 || text_col>=22 && text_col<=25)
                            glyph_char=digit<10 ? "0"+digit:"A"+digit-10;
                    end else begin
                    text_label="RGB HEX                         ";
                    case(text_col)
                        8:digit=center_rgb[23:20];9:digit=center_rgb[19:16];11:digit=center_rgb[15:12];
                        12:digit=center_rgb[11:8];14:digit=center_rgb[7:4];15:digit=center_rgb[3:0];
                    endcase
                    if(text_col==8 || text_col==9 || text_col==11 || text_col==12 || text_col==14 || text_col==15)
                        glyph_char=digit<10 ? "0"+digit:"A"+digit-10;
                end
                end
            endcase
            if(glyph_char==" ")glyph_char=text_label >> ((31-text_col)*8);
            glyph_bits=font(glyph_char,ty[3:1]);
            if(tx[3:0]<10 && ty[3:0]<14 && glyph_bits[4-tx[3:1]])pixel=24'h00ffff;
        end
        tx=view_x-800;ty=view_y<24 ? view_y-8:view_y-208;text_col=tx[8:4];text_row=ty[7:4];
        text_label=0;glyph_char=" ";glyph_bits=0;
        if(view_de && view_x>=800 && view_x<1264 && (view_y>=8 && view_y<24 || view_y>=208 && view_y<256))begin
            if(view_y<24)begin
                if(group_id==2)begin
                    text_label="ALGORITHM                       ";
                    if(text_col>=10 && text_col<18)glyph_char=mode_char({1'b0,effect_mode},text_col-10);
                end else if(group_id==0 && ui_page==0)begin
                    text_label="ID   MATCH                      ";
                    if(text_col==3)glyph_char="0"+bottle_id;
                    if(text_col==11)glyph_char="0"+score_h;
                    if(text_col==12)glyph_char="0"+score_t;
                    if(text_col==13)glyph_char="0"+score_u;
                end else if(group_id==0 && ui_page==1)begin
                    text_label="MENU  /5                        ";if(text_col==5)glyph_char="1"+menu_item;
                end else if(group_id==0 && (ui_page==2 || ui_page==3))begin
                    text_label="CLASS   VIEW  /3                ";
                    if(text_col==6)glyph_char="1"+selected_class;
                    if(text_col==13)glyph_char="0"+board_view;
                end
            end else if(group_id==2)begin
                if(view_y<224)begin
                    text_label="KEY2 MODE  KEY3 LEVEL           ";
                    if(text_col==22)glyph_char="1"+effect_level;
                end
            end else if(group_id==0 && ui_page!=6)begin
                if(view_y<224)begin
                    text_label="LIBRARY  /5 BG   WB             ";
                    if(text_col==8)glyph_char="0"+ready_classes;
                    if(text_col==15)glyph_char="0"+background_ready;
                    if(text_col==20)glyph_char=awb_locked ? "H":"A";
                end else if(view_y<240 && learning_mode)begin
                    text_label="CAPTURE  /08  SAVED V           ";
                    if(text_col==8)glyph_char="0"+bottle_sample_progress;
                    if(text_col==21 && bottle_record_counter!=0 && bottle_record_slot==selected_learn_slot)
                        glyph_char="1"+bottle_record_view;
                end else if(view_y>=240 && ui_page==0)text_label="RGB 3X3 / EDGE / TEMPORAL       ";
            end
            if(glyph_char==" ")glyph_char=text_label >> ((31-text_col)*8);
            glyph_bits=font(glyph_char,ty[3:1]);
            if(tx[3:0]<10 && ty[3:0]<14 && glyph_bits[4-tx[3:1]])pixel=24'h00ffff;
        end
        // A shared Chinese ROM supplies group, class and action text.
        cn_phrase=63;cn_chars={128{1'b1}};cn_x=0;cn_y=0;
        if(view_x>=176 && view_x<688 && view_y>=8 && view_y<40)begin
            cn_phrase=cn_header_q;cn_chars=cn_header_chars;cn_x=view_x-176;cn_y=view_y-8;
        end else if(view_x>=800 && view_x<1248)begin
            cn_x=view_x-800;
            if(view_y>=48 && view_y<80)begin cn_y=view_y-48;cn_phrase=cn_row0_q;cn_chars=cn_row0_chars;end
            else if(view_y>=88 && view_y<120)begin cn_y=view_y-88;cn_phrase=cn_row1_q;cn_chars=cn_row1_chars;end
            else if(view_y>=128 && view_y<160)begin cn_y=view_y-128;cn_phrase=cn_row2_q;cn_chars=cn_row2_chars;end
            else if(view_y>=160 && view_y<192)begin cn_y=view_y-160;cn_phrase=cn_row3_q;cn_chars=cn_row3_chars;end
        end
        cn_bits=cn_glyph_row(cn_chars[cn_x[8:5]*8+:8],cn_y[4:1]);
        if(view_de && cn_bits[15-cn_x[4:1]])pixel=24'hfff2b0;
    end

endmodule

// C12 audio driver. Tone mode suits a passive buzzer; TONE_HZ=0 retains
// continuous low enable for an active buzzer. No generated internal clocks.
module contest_buzzer_driver #(
    parameter integer CLOCK_HZ=50000000,
    parameter integer TONE_HZ=2000
)(input wire clk,rst_n,alert,output wire buzzer_n);
    reg [1:0] alert_sync;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) alert_sync<=0;
        else alert_sync<={alert_sync[0],alert};
    end
    generate if(TONE_HZ==0) begin: active_buzzer
        assign buzzer_n=~alert_sync[1];
    end else begin: passive_buzzer
        localparam integer HALF_PERIOD=CLOCK_HZ/(2*TONE_HZ);
        localparam integer COUNT_WIDTH=HALF_PERIOD<2 ? 1:$clog2(HALF_PERIOD);
        reg [COUNT_WIDTH-1:0] count;
        reg phase;
        always @(posedge clk or negedge rst_n) begin
            if(!rst_n) begin count<=0; phase<=0; end
            else if(!alert_sync[1]) begin count<=0; phase<=0; end
            else if(count==HALF_PERIOD-1) begin count<=0; phase<=~phase; end
            else count<=count+1'b1;
        end
        assign buzzer_n=alert_sync[1] ? ~phase:1'b1;
    end endgenerate
endmodule
