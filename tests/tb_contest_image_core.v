`timescale 1ns/1ps
module tb_contest_image_core;
    reg clk=0,rst_n=0,frame_start=0,de=0;
    reg [3:0] keys_n=4'hf,switches=12;
    reg [31:0] source_id=32'd1;
    reg source_valid=1,cal_changed=0;
    reg [11:0] x=0,y=0;
    reg [23:0] rgb=0;
    wire [23:0] pixel;
    wire [3:0] mode;
    wire target_valid,motion,alert,cal_request,hold_request;
    wire [63:0] board_status;
    wire [11:0] target_x,target_y;
    integer i,j,k,ox,oy,n;
    reg [23:0] saved;
    reg [11:0] old_x;
    always #5 clk=~clk;
    contest_image_core #(.DEBOUNCE(3),.LONG_PRESS(200)) dut(
        .clk(clk),.rst_n(rst_n),.frame_start(frame_start),.de(de),.x(x),.y(y),.rgb(rgb),.keys_n(keys_n),.dip_switches(switches),
        .calibration_changed(cal_changed),.ae_hold_active(1'b0),.ae_active(1'b1),.awb_active(1'b1),.awb_locked(1'b0),.frame_age(8'd2),.frame_age_valid(1'b1),
        .capture_id(source_id),.capture_valid(source_valid),.pixel(pixel),.mode(mode),.target_valid(target_valid),.target_x(target_x),.target_y(target_y),.motion(motion),.alert(alert),.calibration_request(cal_request),.exposure_hold_request(hold_request),.board_status(board_status));
    task tick; begin @(posedge clk); #1; end endtask
    task check; input condition; input [511:0] msg;
        begin if(condition!==1'b1) begin $display("FAIL %0s",msg); $fatal(1); end end
    endtask
    task sample; input [11:0] sx,sy; input [23:0] c;
        begin @(negedge clk); x=sx; y=sy; rgb=c; de=1; tick; @(negedge clk);de=0;repeat(dut.group_id==2 ? 7:3)tick; end
    endtask
    task blank; begin @(negedge clk); de=0; tick; tick; end endtask
    task new_frame; begin
        blank; @(negedge clk); frame_start=1; tick;
        @(negedge clk); frame_start=0; repeat(15) tick;
    end endtask
    task patch; input integer px,py; input [23:0] color;
        integer xx,yy;
        begin
            for(yy=py;yy<py+48;yy=yy+4) begin
                for(xx=px;xx<px+64;xx=xx+4) begin
                    @(negedge clk);x=xx;y=yy;rgb=color;de=1;tick;
                end
                blank;
            end
        end
    endtask
    task press;input integer key_index;begin
        @(negedge clk);de=0;keys_n[key_index]=0;repeat(9)tick;
        @(negedge clk);keys_n[key_index]=1;repeat(9)tick;new_frame;
    end endtask
    // All points are visited even in a static frame, exactly as real video.
    task grid_frame; input integer changed;
        integer xx,yy;
        begin
            for(yy=16;yy<720;yy=yy+32)
                for(xx=16;xx<1280;xx=xx+32) begin
                    if(changed && xx>=432 && xx<=496 && yy>=336 && yy<=368)
                        sample(xx,yy,24'hb0b0b0);
                    else sample(xx,yy,24'h202020);
                    blank;
                end
            new_frame;
        end
    endtask
    reg [3:0] ref_de=0,ref_frame=0,ref_valid=0;
    reg [31:0] ref_capture[0:3];
    integer ri;
    reg old_drink,old_learn;
    always @(posedge clk)if(rst_n)begin
        ref_de={ref_de[2:0],de};ref_frame={ref_frame[2:0],frame_start};ref_valid={ref_valid[2:0],source_valid};
        for(ri=3;ri>0;ri=ri-1)ref_capture[ri]=ref_capture[ri-1];
        ref_capture[0]=source_id;
        #1;
        if(dut.u_bottle.de!==ref_de[3] || dut.u_bottle.frame_start!==ref_frame[3] ||
           dut.u_bottle.capture_id!==ref_capture[3] || dut.u_bottle.capture_valid!==ref_valid[3])
            $fatal(1,"classifier four-clock metadata alignment");
        if(dut.u_bottle.rgb!==dut.smoothed_d || dut.u_bottle.edge_strength!==dut.sobel_d)
            $fatal(1,"classifier bypassed smooth RGB/Sobel preprocessing");
    end
    task confirm;input [2:0] which;begin
        force dut.bottle_id=which;force dut.bottle_status=3'd3;
        @(negedge clk);force dut.bottle_confirm=1'b1;tick;
        @(negedge clk);force dut.bottle_confirm=1'b0;repeat(3)tick;
    end endtask
    initial begin
        for(i=0;i<4;i=i+1)ref_capture[i]=0;
        repeat(3)tick;@(negedge clk);rst_n=1;repeat(8)tick;
        check(dut.group_id==0 && dut.ui_page==0 && mode==0,"default drink-live page");
        check(!hold_request,"SW3=1 enables AUTO");
        switches=13;repeat(10)tick;
        check(!board_status[44],"SW1 cannot mute the hardware SW5 buzzer");
        switches=8;repeat(10)tick;check(hold_request,"SW3=0 requests hold");
        switches=12;repeat(10)tick;
        check(dut.bottle_enabled==0,"camera-only library starts empty");
        for(i=0;i<3;i=i+1)begin patch(400,240,24'he02020);new_frame;end
        check(!target_valid && !motion && !alert,"drink group has no detector/alert");
        press(0);check(dut.group_id==1 && mode==6,"KEY1 enters red group without fourteen-page traversal");
        // The detector rejects orange/pink distractors.
        // must reject them, while accepting a saturated red object.
        for(i=0;i<3;i=i+1) begin patch(400,240,24'hff9040); new_frame; end
        check(!target_valid,"orange distractor rejected");
        for(i=0;i<3;i=i+1) begin patch(400,240,24'hff6432); new_frame; end
        check(!target_valid,"closer red-orange hue rejected");
        for(i=0;i<3;i=i+1) begin patch(400,240,24'hff60a0); new_frame; end
        check(!target_valid,"pink distractor rejected");
        // Isolated red samples spread across the frame cannot form a box.
        for(i=0;i<2;i=i+1) begin
            for(j=0;j<16;j=j+1) begin sample(100+j*48,200,24'hff1010); sample(104+j*48,200,0); end
            new_frame;
        end
        check(!target_valid,"isolated red speckles rejected");
        patch(400,240,24'he02020); new_frame;
        check(!target_valid,"single-frame object not acquired");
        patch(400,240,24'he02020); new_frame;
        check(target_valid && target_x==430 && target_y==262,"two-frame red acquisition");
        patch(400,240,24'he02020); new_frame;
        check(alert,"confirmed target zone alarm");
        old_x=target_x;
        patch(416,240,24'he02020); patch(1000,600,24'he02020); new_frame;
        check(target_x==old_x+4,"ROI ignores remote distractor; IIR reduces jump");
        check(dut.x_digits==16'h0434 && dut.y_digits==16'h0262,"coordinates match current smoothed box in same frame");
        sample(210,128,24'h345678);check(pixel==24'h00ffff,"red X thousands zero is rendered");
        sample(230,128,24'h345678);check(pixel==24'h00ffff,"red X hundreds four is rendered");
        sample(322,128,24'h345678);check(pixel==24'h00ffff,"red Y thousands zero is rendered");
        sample(target_x,target_y,24'h345678); check(pixel==24'h00ff40,"tracking crosshair");
        // Six absent frames clear validity AND stale coordinates.
        for(i=0;i<6;i=i+1) new_frame;
        check(!target_valid && target_x==0 && target_y==0,"lost target cleared without stale coordinates");
        sample(210,128,24'h345678);check(pixel==24'h00ffff,"lost target displays zero rather than missing digits");
        patch(800,400,24'h481010); new_frame;
        patch(800,400,24'h481010); new_frame;
        check(target_valid,"dark saturated red accepted after brightness guard change");
        for(i=0;i<6;i=i+1) new_frame;
        patch(800,400,24'h200404); new_frame;
        patch(800,400,24'h200404); new_frame;
        check(!target_valid,"near-black red-like noise rejected");
        patch(800,400,24'he02020); new_frame;
        patch(800,400,24'he02020); new_frame;
        check(target_valid && target_x==830,"reacquire far from old ROI");
        for(i=0;i<62;i=i+1) new_frame;
        check(!alert,"alarm timeout");

        grid_frame(0); check(!motion,"first complete frame has no false motion");
        grid_frame(0); check(!motion,"static grid has no motion");
        grid_frame(1); check(motion && dut.motion_events==16'h0001,"small patch hits dense grid and counts episode");
        check(dut.motion_box_x0==416 && dut.motion_box_x1==511,"motion region bounds");
        check(dut.motion_x_digits==16'h0463 && dut.motion_y_digits==16'h0351,"motion box center has independent decimal coordinates");
        for(i=0;i<14;i=i+1) grid_frame(1);
        check(!motion,"held motion indication clears after static scene");
        grid_frame(0); check(motion && dut.motion_events==16'h0002,"new motion episode counted");



        press(0);check(dut.group_id==2 && mode==0,"KEY1 enters image-algorithm group");
        check(!target_valid && !motion && !alert && dut.motion_events==0,"leaving tracking clears all detection state");
        press(1);check(mode==1,"KEY2 selects gray only inside algorithm group");
        sample(500,400,24'h306090);check(pixel==24'h606060,"weighted neutral gray");
        press(1);check(mode==2,"KEY2 selects Sobel");
        force dut.clean_edges=8'd0;sample(900,400,24'h123456);check(pixel==0,"Sobel display noise floor");
        force dut.clean_edges=8'd255;sample(900,400,24'h123456);check(pixel==24'hffffff,"median-filtered crisp contour");
        force dut.clean_edges=8'd255;sample(900,400,24'h123456);check(pixel==24'hffffff,"Sobel display saturation");
        release dut.clean_edges;
        for(i=3;i<=6;i=i+1)begin press(1);check(mode==i,"algorithm subgroup order");end
        press(0);check(dut.group_id==0 && dut.ui_page==0,"three groups wrap to drink live");
        press(1);check(dut.ui_page==1,"KEY2 opens drink menu");
        press(1);check(dut.menu_item==1,"KEY2 selects library");
        press(2);check(dut.ui_page==2,"KEY3 opens class picker");
        press(1);check(dut.selected_class==1,"class picker changes independently");
        press(2);check(dut.ui_page==3,"KEY3 enters selected class recording");
        press(3);check(dut.ui_page==2,"KEY4 returns from recording");
        press(3);check(dut.ui_page==1,"KEY4 returns from library");
        press(3);check(dut.ui_page==0,"KEY4 returns to live");
        // All pages use the same processed stream and distinct frame IDs.
        source_id=32'h12345678;source_valid=0;new_frame;
        sample(520,120,24'h60a040);source_valid=1;source_id=32'hdeadbeef;new_frame;
        // Notifications are episode events, never the KNOWN level itself.
        old_drink=board_status[46];confirm(2);
        check(board_status[46]!=old_drink,"new drink confirmation toggles notification");
        old_drink=board_status[46];repeat(20)tick;confirm(2);
        check(board_status[46]==old_drink,"same drink does not repeat notification");
        force dut.bottle_status=3'd2;force dut.bottle_id=3'd0;repeat(8)tick;confirm(2);
        check(board_status[46]==old_drink,"short UNKNOWN does not re-arm notification");
        confirm(3);check(board_status[46]!=old_drink,"confirmed changed class notifies once");
        old_drink=board_status[46];force dut.bottle_status=3'd1;force dut.bottle_id=3'd0;repeat(8)tick;
        confirm(3);check(board_status[46]!=old_drink,"empty scene re-arms same class");
        force dut.ui_page=3'd1;old_drink=board_status[46];confirm(4);
        check(board_status[46]==old_drink,"menu hides recognition notification");
        force dut.ui_page=3'd0;repeat(8)tick;
        check(board_status[46]==old_drink,"returning to live without a confirmation event must not beep");
        release dut.ui_page;force dut.group_id=2'd1;confirm(5);
        check(board_status[46]==old_drink,"red group does not emit drink notification");
        release dut.group_id;release dut.bottle_id;release dut.bottle_status;release dut.bottle_confirm;
        force dut.group_id=2'd0;force dut.ui_page=3'd3;
        old_learn=board_status[47];force dut.bottle_record_counter=8'd1;repeat(5)tick;
        check(board_status[47]!=old_learn,"saved view emits separate double-beep event");
        old_learn=board_status[47];repeat(20)tick;
        check(board_status[47]==old_learn,"saved-view level does not repeat event");
        release dut.bottle_record_counter;release dut.ui_page;release dut.group_id;
        // The bottom-right video region must remain transparent.
        force dut.group_id=2'd0;force dut.ui_page=3'd0;
        for(oy=672;oy<704;oy=oy+1)
            for(ox=1168;ox<1264;ox=ox+1)begin sample(ox,oy,24'h345678);check(pixel==24'h345678,"bottom-right video region transparent");end
        force dut.ui_page=3'd6;sample(900,300,24'h123456);check(pixel==24'hff0000,"native diagnostic red bar");
        sample(400,500,24'h123456);check(pixel==24'h555555,"native diagnostic neutral gray");
        force dut.ui_page=3'd5;force dut.switch_flags=4'b0000;
        sample(800,88,24'h123456);check(dut.cn_phrase==46,"WB page must show write protection before confirmation");
        sample(800,128,24'h123456);check(dut.cn_phrase==48,"WB page explains enabling WRITE");
        force dut.switch_flags=4'b1100;
        sample(800,88,24'h123456);check(dut.cn_phrase==42,"first calibration requests a white reference, not a false destructive warning");
        sample(320,200,24'h123456);check(pixel==24'hffffff,"WB calibration frame matches central camera ROI");
        sample(766,106,24'h123456);check(pixel==24'h123456,"WB page must not use the narrow bottle ROI");
        release dut.switch_flags;release dut.ui_page;release dut.group_id;
        $display("PASS  grouped core, enable-polarity switches, SW1 no mute, visible WB protection/instructions/ROI, detector isolation, team removal, aligned preprocessing and episode notifications");$finish;
    end
    initial begin #20000000;$fatal(1,"watchdog");end
endmodule
