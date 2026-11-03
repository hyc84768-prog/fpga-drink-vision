// four-key grouped controls. All actions commit on frame_start.
// KEY1 group, KEY2 select, KEY3 enter/sample, KEY4 back/cancel.
module contest_ui_control #(
    parameter integer DEBOUNCE=750000, CLOCK_HZ=75000000, CAL_TIMEOUT_MS=3000
)(
    input wire clk,rst_n,frame_start,
    input wire [3:0] key_n,switches,
    input wire recording,library_present,calibration_changed,
    output reg [1:0] group_id,
    output reg [2:0] page,menu_item,selected_class,effect_mode,
    output reg [1:0] effect_level,
    output reg [3:0] switches_filtered,
    output wire [2:0] learn_slot,
    output reg learn_request,learn_cancel,calibration_request,group_changed,
    output reg identify_request,
    output reg write_blocked,cal_timeout
);
    localparam LIVE=0,MENU=1,LIBRARY=2,RECORD=3,BACKGROUND=4,
               WB_CONFIRM=5,DIAG=6,WB_WAIT=7;
    localparam integer DB_LIMIT=DEBOUNCE<1 ? 1:DEBOUNCE;
    localparam integer DB_WIDTH=DB_LIMIT<2 ? 1:$clog2(DB_LIMIT);
    localparam integer MS_CYCLES=CLOCK_HZ/1000<1 ? 1:CLOCK_HZ/1000;
    localparam integer MS_WIDTH=MS_CYCLES<2 ? 1:$clog2(MS_CYCLES);
    reg [3:0] key_meta,key_sync,key_stable,key_armed,release_events;
    reg [3:0] switch_meta,switch_sync;
    reg [DB_WIDTH-1:0] key_count[0:3],switch_count[0:3];
    reg [3:0] pending_events;
    wire [3:0] events=pending_events|release_events;
    wire training_page=group_id==0 && (page==RECORD || page==BACKGROUND);
    reg cal_done_pending;
    reg [MS_WIDTH-1:0] wait_divider;
    reg [15:0] wait_ms;
    integer k;

    assign learn_slot=page==BACKGROUND ? 3'd5:selected_class;

    // The physical switches need the same synchronization/debounce as keys.
    // A press first arms its key, and only a debounced release posts an event.
    // Busy sampling and in-flight calibration do not queue a delayed action.
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            key_meta<=4'hf;key_sync<=4'hf;key_stable<=4'hf;
            key_armed<=0;release_events<=0;
            switch_meta<=0;switch_sync<=0;switches_filtered<=0;
            for(k=0;k<4;k=k+1) begin key_count[k]<=0;switch_count[k]<=0;end
        end else begin
            key_meta<=key_n;key_sync<=key_meta;
            switch_meta<=switches;switch_sync<=switch_meta;
            release_events<=0;
            for(k=0;k<4;k=k+1) begin
                if(key_sync[k]==key_stable[k]) key_count[k]<=0;
                else if(key_count[k]==DB_LIMIT-1) begin
                    key_count[k]<=0;key_stable[k]<=key_sync[k];
                    if(!key_sync[k]) key_armed[k]<=page!=WB_WAIT &&
                        !(k==2 && training_page && recording);
                    else begin
                        if(key_armed[k]) release_events[k]<=1;
                        key_armed[k]<=0;
                    end
                end else key_count[k]<=key_count[k]+1'b1;
                if(switch_sync[k]==switches_filtered[k]) switch_count[k]<=0;
                else if(switch_count[k]==DB_LIMIT-1) begin
                    switch_count[k]<=0;switches_filtered[k]<=switch_sync[k];
                end else switch_count[k]<=switch_count[k]+1'b1;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            pending_events<=0;cal_done_pending<=0;wait_divider<=0;wait_ms<=0;
        end else begin
            if(frame_start) begin pending_events<=0;cal_done_pending<=0;end
            else begin
                pending_events<=events;
                if(calibration_changed) cal_done_pending<=1;
            end
            if(page!=WB_WAIT) begin wait_divider<=0;wait_ms<=0;end
            else if(wait_divider==MS_CYCLES-1) begin
                wait_divider<=0;
                if(wait_ms<16'hffff) wait_ms<=wait_ms+1'b1;
            end else wait_divider<=wait_divider+1'b1;
        end
    end

    // Frame-boundary priority: completed calibration, timeout, K1,K4,K2,K3.
    // library_present deliberately does not bypass maintenance confirmation.
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            group_id<=0;page<=LIVE;menu_item<=0;selected_class<=0;effect_mode<=0;
            effect_level<=1;
            identify_request<=0;learn_request<=0;learn_cancel<=0;calibration_request<=0;group_changed<=0;
            write_blocked<=0;cal_timeout<=0;
        end else begin
            identify_request<=0;learn_request<=0;learn_cancel<=0;calibration_request<=0;group_changed<=0;
            if(frame_start) begin
                if(switches_filtered[3])write_blocked<=0;
                if(page==WB_WAIT) begin
                    if(cal_done_pending || calibration_changed) begin
                        page<=LIVE;write_blocked<=0;cal_timeout<=0;
                    end else if(wait_ms>=CAL_TIMEOUT_MS) begin
                        page<=WB_CONFIRM;cal_timeout<=1;
                    end
                    // Navigation here cannot cancel an already-issued request.
                end else if(|events) begin
                    write_blocked<=0;cal_timeout<=0;
                    if(events[0]) begin
                        if(training_page || recording) learn_cancel<=1;
                        group_id<=group_id==2 ? 0:group_id+1'b1;
                        page<=LIVE;menu_item<=0;group_changed<=1;
                    end else if(events[3]) begin
                        if(group_id==0) begin
                            case(page)
                                LIVE:begin page<=MENU;menu_item<=0;end
                                MENU:page<=LIVE;
                                LIBRARY:page<=MENU;
                                RECORD:begin page<=LIBRARY;learn_cancel<=1;end
                                BACKGROUND:begin page<=MENU;learn_cancel<=1;end
                                default:page<=MENU;
                            endcase
                        end else page<=LIVE;
                    end else if(events[1]) begin
                        if(group_id==2) effect_mode<=effect_mode==6 ? 0:effect_mode+1'b1;
                        else if(group_id==0) begin
                            case(page)
                                LIVE:begin page<=MENU;menu_item<=0;end
                                MENU:menu_item<=menu_item==4 ? 0:menu_item+1'b1;
                                LIBRARY:selected_class<=selected_class==4 ? 0:selected_class+1'b1;
                                default:begin end
                            endcase
                        end
                    end else if(events[2] && group_id==2) begin
                        effect_level<=effect_level==2 ? 0:effect_level+1'b1;
                    end else if(events[2] && group_id==0) begin
                        case(page)
                            LIVE:identify_request<=1;
                            MENU:case(menu_item)
                                0:page<=LIVE;
                                1:page<=LIBRARY;
                                2:page<=BACKGROUND;
                                3:page<=WB_CONFIRM;
                                default:page<=DIAG;
                            endcase
                            LIBRARY:page<=RECORD;
                            RECORD,BACKGROUND:if(!recording) begin
                                if(!switches_filtered[3]) write_blocked<=1;
                                else learn_request<=1;
                            end
                            WB_CONFIRM:begin
                                if(!switches_filtered[3]) write_blocked<=1;
                                else begin calibration_request<=1;page<=WB_WAIT;end
                            end
                            default:begin end
                        endcase
                    end
                end
            end
        end
    end
endmodule
