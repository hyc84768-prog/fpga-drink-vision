`timescale 1ns/1ps
// Procedural video integration checks only. Forced IDs/states exercise OSD,
// never recognition accuracy; live three-view enrollment is unit-tested.
module tb_bottle_replay;
    reg clk=0,rst_n=0,vs=0,hs=0,de=0,user=0,last=0;
    reg [23:0] rgb=0;
    reg [31:0] source_id=0;
    wire rd,ovs,ohs,ode,alert;
    wire board_submit,cal_request,hold_request;
    wire [63:0] board_status;
    wire [23:0] pixel;
    reg [6:0] ref_de=0,ref_vs=0,ref_hs=0;
    reg [23:0] ref_rgb[0:6];
    integer ref_x[0:6],ref_y[0:6];
    integer frame,row=0,col=0,fd=0,captured=0,total=0,i;
    integer checked_original=0,checked_demo=0,checked_bars=0,checked_gray=0,name_strokes=0;
    integer diagnostic,expected_gray,team_cleared=0;
    reg [23:0] expected;
    always #5 clk=~clk;
    hdmi_mixer dut(.I_clk(clk),.I_rst_n(rst_n),.I_video_vsync(vs),.I_video_hsync(hs),
      .I_video_de(de),.I_video_user(user),.I_video_last(last),.I_debug_status(4'b1111),
      .I_keys_n(4'hf),.I_switches(4'd0),.I_ae_hold_active(1'b0),.I_ae_active(1'b1),.I_awb_active(1'b1),.I_awb_locked(1'b1),
      .I_calibration_changed(1'b0),.I_frame_age(8'd2),.I_frame_age_valid(1'b1),
      .I_capture_id(source_id),.I_capture_valid(1'b1),
      .O_target_alert(alert),.O_video_rd_en(rd),.I_video_rd_data(rgb),
      .O_board_status(board_status),.O_board_submit(board_submit),.O_calibration_request(cal_request),.O_exposure_hold_request(hold_request),
      .O_hdmi_vsync(ovs),.O_hdmi_hsync(ohs),.O_hdmi_de(ode),.O_hdmi_data(pixel));
    task overlay_fixture;
        begin
            force dut.u_contest_image_core.target_valid=1'b1;
            force dut.u_contest_image_core.tracking_live=1'b1;
            force dut.u_contest_image_core.box_min_x=12'd900;
            force dut.u_contest_image_core.box_max_x=12'd1000;
            force dut.u_contest_image_core.box_min_y=12'd350;
            force dut.u_contest_image_core.box_max_y=12'd450;
            force dut.u_contest_image_core.target_x=12'd950;
            force dut.u_contest_image_core.target_y=12'd400;
            force dut.u_contest_image_core.motion=1'b1;
            force dut.u_contest_image_core.motion_box_x0=12'd800;
            force dut.u_contest_image_core.motion_box_x1=12'd850;
            force dut.u_contest_image_core.motion_box_y0=12'd300;
            force dut.u_contest_image_core.motion_box_y1=12'd400;
            force dut.u_contest_image_core.alert=1'b1;
        end
    endtask
    task release_fixture;
        begin
            release dut.u_contest_image_core.target_valid;
            release dut.u_contest_image_core.tracking_live;
            release dut.u_contest_image_core.box_min_x;
            release dut.u_contest_image_core.box_max_x;
            release dut.u_contest_image_core.box_min_y;
            release dut.u_contest_image_core.box_max_y;
            release dut.u_contest_image_core.target_x;
            release dut.u_contest_image_core.target_y;
            release dut.u_contest_image_core.motion;
            release dut.u_contest_image_core.motion_box_x0;
            release dut.u_contest_image_core.motion_box_x1;
            release dut.u_contest_image_core.motion_box_y0;
            release dut.u_contest_image_core.motion_box_y1;
            release dut.u_contest_image_core.alert;
        end
    endtask
    always @(posedge clk) if(rst_n)begin
        ref_de={ref_de[5:0],de};ref_vs={ref_vs[5:0],vs};ref_hs={ref_hs[5:0],hs};
        for(i=6;i>0;i=i-1)begin ref_rgb[i]=ref_rgb[i-1];ref_x[i]=ref_x[i-1];ref_y[i]=ref_y[i-1];end
        ref_rgb[0]=rgb;ref_x[0]=col;ref_y[0]=row;
        #1;
        if(ode!==ref_de[6] || ovs!==ref_vs[6] || ohs!==ref_hs[6])$fatal(1,"live replay sync latency mismatch");
        if(ode)begin
            if(^pixel===1'bx)$fatal(1,"unknown HDMI output in synthetic live replay");
            if(fd!=0)$fdisplay(fd,"%06h",pixel);
            captured=captured+1;
            if(frame!=2 && ref_x[6]>=1168 && ref_x[6]<1264 && ref_y[6]>=672 && ref_y[6]<704)begin
                if(pixel!==ref_rgb[6])$fatal(1,"unexpected bottom-right overlay");
                team_cleared=team_cleared+1;
            end
            if(frame==0)begin
                if(ref_x[6]>400 && ref_y[6]>=256 && ref_y[6]<570 &&
                  !(ref_y[6]<616 && (ref_x[6]>=512 && ref_x[6]<514 || ref_x[6]>=766 && ref_x[6]<768)))begin
                    if(ref_x[6]>=544 && ref_x[6]<736 && ref_y[6]>=168 && ref_y[6]<552 && (ref_x[6]==544 || ref_x[6]==735 || ref_y[6]==168 || ref_y[6]==551))begin
                        if(pixel!==24'hffff40)$fatal(1,"label guide alignment mismatch");
                    end else if(pixel!==ref_rgb[6])$fatal(1,"demo overlay leaked into M0 at %0d,%0d",ref_x[6],ref_y[6]);
                    checked_original=checked_original+1;
                end
                if(ref_x[6]>=816 && ref_x[6]<1072 && ref_y[6]>=48 && ref_y[6]<80 && pixel==24'hfff2b0)
                    name_strokes=name_strokes+1;
            end
            if(frame==1)begin
                if(ref_x[6]>=816 && ref_x[6]<1072 && ref_y[6]>=48 && ref_y[6]<80)
                    if(pixel!==ref_rgb[6])$fatal(1,"bottle OSD leaked into standalone M6 demo");
                if(ref_x[6]==900 && ref_y[6]==350 || ref_x[6]==950 && ref_y[6]==400)begin
                    if(pixel!==24'h00ff40)$fatal(1,"missing standalone red-tracking overlay");checked_demo=checked_demo+1;
                end
                if(ref_x[6]==800 && ref_y[6]==300)begin
                    if(pixel!==24'hffc000)$fatal(1,"missing standalone motion overlay");checked_demo=checked_demo+1;
                end
                if(ref_x[6]==500 && ref_y[6]==2)begin
                    if(pixel!==24'hff2030)$fatal(1,"missing standalone alert bar");checked_demo=checked_demo+1;
                end
            end
            if(frame==2 && ref_x[6]>=400)begin
                if(ref_y[6]>=200 && ref_y[6]<432)begin
                    if(ref_x[6]<480)expected=24'h00ffff;
                    else if(ref_x[6]<640)expected=24'h00ff00;
                    else if(ref_x[6]<800)expected=24'hff00ff;
                    else if(ref_x[6]<960)expected=24'hff0000;
                    else if(ref_x[6]<1120)expected=24'h0000ff;
                    else expected=0;
                    if(pixel!==expected)$fatal(1,"M13 native color/overlay isolation %0d,%0d %h/%h",ref_x[6],ref_y[6],pixel,expected);
                    checked_bars=checked_bars+1;
                end
                if(ref_y[6]>=432 && ref_y[6]<570)begin
                    expected_gray=(ref_x[6]/80)*17;
                    if(pixel!=={3{expected_gray[7:0]}})$fatal(1,"M13 native gray/overlay isolation %0d,%0d",ref_x[6],ref_y[6]);
                    checked_gray=checked_gray+1;
                end
            end
        end
    end
    initial begin
        for(i=0;i<7;i=i+1)begin ref_rgb[i]=0;ref_x[i]=0;ref_y[i]=0;end
        repeat(5)@(negedge clk);rst_n=1;repeat(6000)@(negedge clk);
        if(dut.u_contest_image_core.bottle_enabled!==0 || dut.u_contest_image_core.bottle_sample_counts!==0)
            $fatal(1,"phone/photo seeds enabled on reset");
        overlay_fixture;
        for(frame=0;frame<3;frame=frame+1)begin
            case(frame)
                0:begin
                    force dut.u_contest_image_core.group_id=2'd0;
                    force dut.u_contest_image_core.ui_page=3'd0;
                    force dut.u_contest_image_core.bottle_id=3'd2;
                    force dut.u_contest_image_core.bottle_status=3'd3;
                    force dut.u_contest_image_core.bottle_score=7'd88;
                    force dut.u_contest_image_core.bottle_enabled=5'b11111;
                    force dut.u_contest_image_core.bottle_sample_counts=10'h3ff;
                end
                1:begin
                    release dut.u_contest_image_core.bottle_id;
                    release dut.u_contest_image_core.bottle_status;
                    release dut.u_contest_image_core.bottle_score;
                    release dut.u_contest_image_core.bottle_enabled;
                    release dut.u_contest_image_core.bottle_sample_counts;
                    force dut.u_contest_image_core.group_id=2'd1;
                end
                2:begin force dut.u_contest_image_core.group_id=2'd0;force dut.u_contest_image_core.ui_page=3'd6;end
            endcase
            source_id=frame+1;vs=1;repeat(5)@(negedge clk);vs=0;
            repeat(7000)@(negedge clk);
            fd=0;captured=0;
            if($test$plusargs("CAPTURE"))case(frame)
                0:fd=$fopen("grouped_original_output.hex","w");
                1:fd=$fopen("grouped_demo_output.hex","w");
                2:fd=$fopen("grouped_diag_output.hex","w");
            endcase
            user=1;@(negedge clk);user=0;
            for(row=0;row<720;row=row+1)begin
                for(col=0;col<1280;col=col+1)begin
                    de=1;last=col==1279;rgb={8'h50,col[7:0],row[7:0]};
                    @(negedge clk);
                end
                de=0;last=0;hs=1;repeat(8)@(negedge clk);hs=0;repeat(8)@(negedge clk);
            end
            repeat(12)@(negedge clk);
            if(captured!=921600)$fatal(1,"live capture frame size %0d",captured);
            total=total+1;if(fd!=0)$fclose(fd);fd=0;
        end
        release_fixture;repeat(10)@(negedge clk);
        if(alert!==0 || dut.u_contest_image_core.target_valid!==0 || dut.u_contest_image_core.motion!==0)
            $fatal(1,"leaving standalone demo retained detector/alert state");
        if(total!=3 || checked_original!=(1280-401-4)*(570-256) || checked_demo!=4 || checked_bars<200000 || checked_gray<120000 || name_strokes<100 || team_cleared!=6144)
            $fatal(1,"incomplete live/OSD/diagnostic coverage %0d/%0d/%0d/%0d/%0d",checked_original,checked_demo,checked_bars,checked_gray,name_strokes);
        $display("PASS  no-seed reset, grouped drink/red/diagnostic full-720p HDMI, Chinese name strokes, isolated overlays, native neutral gray, no-X and seven-clock sync (OSD fixtures, not recognition accuracy)");$finish;
    end
    initial begin #50000000;$fatal(1,"watchdog");end
endmodule
