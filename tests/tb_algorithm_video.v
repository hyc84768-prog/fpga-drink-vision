`timescale 1ns/1ps
module tb_algorithm_video;
    reg clk=0,rst_n=0,vs=0,hs=0,de=0,user=0,last=0;
    reg [23:0] rgb=0;
    wire ovs,ohs,ode;wire [23:0] pixel;
    reg [10:0] rd=0,rv=0,rh=0;
    reg [23:0] rp[0:10];
    integer rx[0:10],ry[0:10];
    integer row=0,col=0,i,mode=0,active_count=0,total=0,body=0;
    always #5 clk=~clk;
    hdmi_mixer #(.IMG_HEIGHT(96)) dut(.I_clk(clk),.I_rst_n(rst_n),
        .I_video_vsync(vs),.I_video_hsync(hs),.I_video_de(de),.I_video_user(user),.I_video_last(last),
        .I_debug_status(4'b1111),.I_keys_n(4'hf),.I_switches(4'd12),.I_ae_hold_active(1'b0),
        .I_ae_active(1'b1),.I_awb_active(1'b1),.I_awb_locked(1'b0),.I_calibration_changed(1'b0),
        .I_frame_age(8'd2),.I_frame_age_valid(1'b1),.I_capture_id(32'd1),.I_capture_valid(1'b1),
        .I_video_rd_data(rgb),.O_hdmi_vsync(ovs),.O_hdmi_hsync(ohs),.O_hdmi_de(ode),.O_hdmi_data(pixel));
    always @(posedge clk)if(rst_n)begin
        rd={rd[9:0],de};rv={rv[9:0],vs};rh={rh[9:0],hs};
        for(i=10;i>0;i=i-1)begin rp[i]=rp[i-1];rx[i]=rx[i-1];ry[i]=ry[i-1];end
        rp[0]=rgb;rx[0]=col;ry[0]=row;
        #1;
        if(ode!==rd[10] || ovs!==rv[10] || ohs!==rh[10])$fatal(1,"algorithm eleven-clock sync");
        if(ode)begin
            if(^pixel===1'bx)$fatal(1,"unknown algorithm video");
            active_count=active_count+1;total=total+1;
            // Between the two OSD columns, outside both logos and all text.
            if(rx[10]>=700 && rx[10]<800)begin
                if(mode==0 && pixel!==rp[10])$fatal(1,"algorithm original RGB alignment");
                if(mode==1 || mode==2 || mode==4 || mode==5 || mode==6)
                    if(pixel[23:16]!==pixel[15:8] || pixel[15:8]!==pixel[7:0])$fatal(1,"nonneutral gray path");
                if(mode==2 || mode==6)if(pixel!==0 && pixel!==24'hffffff)$fatal(1,"nonbinary edge/binary body");
                body=body+1;
            end
            if(rx[10]==54 && ry[10]==34 && pixel!==24'hd3d4d8)$fatal(1,"algorithm logo alignment");
        end
    end
    initial begin
        for(i=0;i<11;i=i+1)begin rp[i]=0;rx[i]=0;ry[i]=0;end
        repeat(5)@(negedge clk);rst_n=1;
        force dut.u_contest_image_core.group_id=2'd2;
        for(mode=0;mode<7;mode=mode+1)begin
            force dut.u_contest_image_core.effect_mode=mode;
            vs=1;repeat(40)@(negedge clk);vs=0;repeat(10)@(negedge clk);
            active_count=0;user=1;@(negedge clk);user=0;
            for(row=0;row<96;row=row+1)begin
                for(col=0;col<1280;col=col+1)begin
                    de=1;last=col==1279;rgb={col[7:0],row[7:0],8'h60};@(negedge clk);
                end
                de=0;last=0;hs=1;repeat(24)@(negedge clk);hs=0;repeat(8)@(negedge clk);
            end
            repeat(25)@(negedge clk);
            if(active_count!=122880)$fatal(1,"algorithm raster changed width/height %0d",active_count);
        end
        if(body!=67200 || total!=860160)$fatal(1,"insufficient mode coverage");
        $display("PASS seven algorithm modes, eleven-clock RGB/DE/sync/logo alignment, neutral gray paths, crisp edges, binary values and no-X raster; drink/red remain seven clocks");$finish;
    end
    initial begin #15000000;$fatal(1,"watchdog");end
endmodule
