`timescale 1ns/1ps
module tb_hdmi_mixer;
    reg clk=0,rst_n=0,vs=0,hs=0,de=0,user=0,last=0;
    reg [23:0] rgb=0;
    wire rd,ovs,ohs,ode,alert;
    wire board_submit,cal_request,hold_request;
    wire [63:0] board_status;
    wire [23:0] pixel;
    reg [6:0] ref_de=0,ref_vs=0,ref_hs=0;
    reg [23:0] ref_rgb[0:6];
    reg [11:0] ref_x[0:6],ref_y[0:6];
    reg [23:0] anniversary_expected[0:51455];
    reg [23:0] expected_anniversary_pixel;
    integer anniversary_checked=0,transparent_spaces=0,team_cleared=0;
    integer row,col,i,checked=0,white=0,starts=0,logos=0,capture=0,fd;
    always #5 clk=~clk;
    hdmi_mixer dut(.I_clk(clk),.I_rst_n(rst_n),.I_video_vsync(vs),.I_video_hsync(hs),
        .I_video_de(de),.I_video_user(user),.I_video_last(last),.I_debug_status(4'b1111),
        .I_calibration_changed(1'b0),.I_keys_n(4'hf),.I_switches(4'd0),.I_ae_hold_active(1'b0),.I_ae_active(1'b1),.I_awb_active(1'b1),.I_awb_locked(1'b0),.I_frame_age(8'd2),.I_frame_age_valid(1'b1),
        .I_capture_id(32'd1),.I_capture_valid(1'b1),.O_target_alert(alert),.O_video_rd_en(rd),.I_video_rd_data(rgb),
        .O_board_status(board_status),.O_board_submit(board_submit),.O_calibration_request(cal_request),.O_exposure_hold_request(hold_request),
        .O_hdmi_vsync(ovs),.O_hdmi_hsync(ohs),.O_hdmi_de(ode),.O_hdmi_data(pixel));
    always @(posedge clk) if(rst_n) begin
        ref_de={ref_de[5:0],de}; ref_vs={ref_vs[5:0],vs}; ref_hs={ref_hs[5:0],hs};
        for(i=6;i>0;i=i-1) begin ref_rgb[i]=ref_rgb[i-1]; ref_x[i]=ref_x[i-1]; ref_y[i]=ref_y[i-1]; end
        ref_rgb[0]=rgb; ref_x[0]=col; ref_y[0]=row;
        if(dut.S_video_vsync_2d && !dut.S_video_vsync_3d) starts=starts+1;
        #1;
        if(ode!==ref_de[6] || ovs!==ref_vs[6] || ohs!==ref_hs[6]) $fatal(1,"sync pipeline mismatch");
        // Pattern contains no red; exclude OSD, Logo, team and frame border.
        if(ode && dut.u_contest_image_core.x_d>400 && dut.u_contest_image_core.y_d>=256 && dut.u_contest_image_core.y_d<600 && !(ref_x[6]>=512 && ref_x[6]<514 || ref_x[6]>=766 && ref_x[6]<768)) begin
            if(ref_x[6]>=544 && ref_x[6]<736 && ref_y[6]>=168 && ref_y[6]<552 && (ref_x[6]==544 || ref_x[6]==735 || ref_y[6]==168 || ref_y[6]==551))begin
                        if(pixel!==24'hffff40)$fatal(1,"label guide alignment mismatch");
                    end else if(pixel!==ref_rgb[6]) $fatal(1,"RGB/sync alignment mismatch: %h != %h",pixel,ref_rgb[6]);
            checked=checked+1;
        end
        if(ode && pixel==24'h00ffff) white=white+1;
        if(ode && ref_x[6]==54 && ref_y[6]==34) begin
            if(pixel!==24'hd3d4d8) $fatal(1,"Logo pixel/address alignment mismatch");
            logos=logos+1;
        end
        if(ode && ref_x[6]>=16 && ref_x[6]<400 && ref_y[6]>=570 && ref_y[6]<704) begin
            expected_anniversary_pixel=anniversary_expected[(ref_y[6]-570)*384+ref_x[6]-16];
            if(expected_anniversary_pixel[23:16]<=8 && expected_anniversary_pixel[15:8]<=8 && expected_anniversary_pixel[7:0]<=8)
                expected_anniversary_pixel=ref_rgb[6];
            if(pixel!==expected_anniversary_pixel)
                $fatal(1,"Anniversary ROM/pipeline mismatch at %0d,%0d",ref_x[6],ref_y[6]);
            anniversary_checked=anniversary_checked+1;
        end
        if(ode && (ref_x[6]==366 && ref_y[6]==166 || ref_x[6]==1262 && ref_y[6]==134 || ref_x[6]==1161 && ref_y[6]==665))begin
            if(pixel!==ref_rgb[6])$fatal(1,"text spacer/background is not transparent at %0d,%0d",ref_x[6],ref_y[6]);
            transparent_spaces=transparent_spaces+1;
        end
        if(ode && ref_x[6]>=1168 && ref_x[6]<1264 && ref_y[6]>=672 && ref_y[6]<704)begin
            if(pixel!==ref_rgb[6])$fatal(1,"bottom-right video region is not transparent");
            team_cleared=team_cleared+1;
        end
        if(capture && ode) $fdisplay(fd,"%06h",pixel);
    end
    task tick; begin @(posedge clk); #2; end endtask
    initial begin
        $readmemh("anniversary_expected.hex",anniversary_expected);
        for(i=0;i<7;i=i+1) begin ref_rgb[i]=0; ref_x[i]=0; ref_y[i]=0; end
        if($test$plusargs("CAPTURE")) begin capture=1; fd=$fopen("mixer_preview.hex","w"); end
        repeat(5) tick; @(negedge clk); rst_n=1;
        vs=1; repeat(5) tick; @(negedge clk); vs=0;
        // User pulse precedes active data, with genuine blanking between rows.
        user=1; tick; @(negedge clk); user=0;
        for(row=0;row<720;row=row+1) begin
            for(col=0;col<1280;col=col+1) begin
                @(negedge clk); de=1; last=(col==1279);
                rgb={8'h20,col[7:0],row[7:0]}; tick;
            end
            @(negedge clk); de=0; last=0; rgb=0; hs=1;
            repeat(8) tick; @(negedge clk); hs=0; repeat(8) tick;
        end
        repeat(8) tick;
        if(checked<100000 || white<100 || starts!=1 || logos!=1 || anniversary_checked!=51456 || transparent_spaces!=3 || team_cleared!=3072)
            $fatal(1,"insufficient active video/transparent-region/Logo/frame pulse coverage");
        if(capture) $fclose(fd);
        $display("PASS  HDMI seven-clock pipeline, transparent grouped OSD, all 3072 bottom-right video pixels transparent, all 51456 masked anniversary pixels, original Logo and frame pulse");
        $finish;
    end
    initial begin #20000000; $fatal(1,"watchdog"); end
endmodule
