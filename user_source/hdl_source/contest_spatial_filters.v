// Four pixel clocks of latency on every path. The trailing 3x3 window ends
// at (x,y); first two rows/columns bypass median and suppress Sobel.
module contest_spatial_filters #(parameter integer WIDTH=1280)(
    input wire clk,rst_n,de,
    input wire [11:0] x,y,
    input wire [23:0] rgb,
    output wire out_de,
    output wire [11:0] out_x,out_y,
    output wire [23:0] original,cartoon,
    output wire [7:0] gray,median,sobel,
    output wire [23:0] smoothed
);
    wire [9:0] lum_sum={2'b0,rgb[23:16]}+{1'b0,rgb[15:8],1'b0}+{2'b0,rgb[7:0]};
    wire [7:0] lum=lum_sum[9:2];
    reg [7:0] line1[0:WIDTH-1],line2[0:WIDTH-1];
    reg [23:0] color_line1[0:WIDTH-1],color_line2[0:WIDTH-1];
    reg [23:0] above_color1,above_color2;
    reg [23:0] ct0,ct1,cm0,cm1,cb0,cb1;
    reg [7:0] above1,above2;
    reg [3:0] valid_pipe;
    reg [11:0] xp[0:3],yp[0:3];
    reg [23:0] rp[0:3];
    reg [7:0] lp[0:3];
    reg [7:0] t0,t1,m0,m1,b0,b1;
    reg [7:0] lo0,mi0,hi0,lo1,mi1,hi1,lo2,mi2,hi2;
    reg [7:0] low_candidate,mid_candidate,high_candidate,median_q;
    reg signed [11:0] gx,gy;
    wire [11:0] ax=gx[11] ? -gx:gx, ay=gy[11] ? -gy:gy;
    reg [12:0] magnitude;
    reg [7:0] sobel_q;
    reg good2,good3;
    reg [23:0] cartoon4,smoothed4;
    reg [9:0] cr0,cr1,cr2,cg0,cg1,cg2,cc0,cc1,cc2;
    reg [11:0] blur_r,blur_g,blur_b;
    function [9:0] weighted_row;
        input [7:0] a,b,c;
        begin weighted_row={2'b0,a}+{1'b0,b,1'b0}+{2'b0,c}; end
    endfunction
    function [23:0] quantize;
        input [23:0] value;
        begin quantize={value[23:21],5'b10000,value[15:13],5'b10000,value[7:5],5'b10000}; end
    endfunction
    function [7:0] min3;
        input [7:0] a,b,c;
        begin min3=(a<b ? a:b)<c ? (a<b ? a:b):c; end
    endfunction
    function [7:0] max3;
        input [7:0] a,b,c;
        begin max3=(a>b ? a:b)>c ? (a>b ? a:b):c; end
    endfunction
    function [7:0] med3;
        input [7:0] a,b,c;
        begin med3=a>b ? (b>c ? b:(a>c ? c:a)):(a>c ? a:(b>c ? c:b)); end
    endfunction
    // Separate delayed write address lets both line stores infer synchronous RAM.
    always @(posedge clk) begin
        if(de && x<WIDTH) begin above1<=line1[x]; above2<=line2[x]; line1[x]<=lum; end
        if(de && x<WIDTH) begin
            above_color1<=color_line1[x]; above_color2<=color_line2[x]; color_line1[x]<=rgb;
        end
        if(valid_pipe[0] && xp[0]<WIDTH) line2[xp[0]]<=above1;
        if(valid_pipe[0] && xp[0]<WIDTH) color_line2[xp[0]]<=above_color1;
    end
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            valid_pipe<=0; t0<=0;t1<=0;m0<=0;m1<=0;b0<=0;b1<=0;
            lo0<=0;mi0<=0;hi0<=0;lo1<=0;mi1<=0;hi1<=0;lo2<=0;mi2<=0;hi2<=0;
            low_candidate<=0;mid_candidate<=0;high_candidate<=0;median_q<=0;
            gx<=0;gy<=0;magnitude<=0;sobel_q<=0;good2<=0;good3<=0;
            cartoon4<=0;smoothed4<=0;ct0<=0;ct1<=0;cm0<=0;cm1<=0;cb0<=0;cb1<=0;
            cr0<=0;cr1<=0;cr2<=0;cg0<=0;cg1<=0;cg2<=0;cc0<=0;cc1<=0;cc2<=0;
            blur_r<=0;blur_g<=0;blur_b<=0;
            for(i=0;i<4;i=i+1) begin xp[i]<=0;yp[i]<=0;rp[i]<=0;lp[i]<=0;end
        end else begin
            valid_pipe<={valid_pipe[2:0],de};
            xp[0]<=x;yp[0]<=y;rp[0]<=rgb;lp[0]<=lum;
            for(i=1;i<4;i=i+1) begin xp[i]<=xp[i-1];yp[i]<=yp[i-1];rp[i]<=rp[i-1];lp[i]<=lp[i-1];end
            if(valid_pipe[0]) begin
                t0<=xp[0]==0 ? above2:t1;t1<=above2;
                m0<=xp[0]==0 ? above1:m1;m1<=above1;
                b0<=xp[0]==0 ? lp[0]:b1;b1<=lp[0];
                ct0<=xp[0]==0 ? above_color2:ct1;ct1<=above_color2;
                cm0<=xp[0]==0 ? above_color1:cm1;cm1<=above_color1;
                cb0<=xp[0]==0 ? rp[0]:cb1;cb1<=rp[0];
            end
            lo0<=min3(t0,t1,above2);mi0<=med3(t0,t1,above2);hi0<=max3(t0,t1,above2);
            lo1<=min3(m0,m1,above1);mi1<=med3(m0,m1,above1);hi1<=max3(m0,m1,above1);
            lo2<=min3(b0,b1,lp[0]);mi2<=med3(b0,b1,lp[0]);hi2<=max3(b0,b1,lp[0]);
            gx<=($signed({4'd0,above2})+($signed({4'd0,above1})<<<1)+$signed({4'd0,lp[0]}))-
                ($signed({4'd0,t0})+($signed({4'd0,m0})<<<1)+$signed({4'd0,b0}));
            gy<=($signed({4'd0,b0})+($signed({4'd0,b1})<<<1)+$signed({4'd0,lp[0]}))-
                ($signed({4'd0,t0})+($signed({4'd0,t1})<<<1)+$signed({4'd0,above2}));
            good2<=valid_pipe[0] && xp[0]>=2 && yp[0]>=2;
            low_candidate<=max3(lo0,lo1,lo2);mid_candidate<=med3(mi0,mi1,mi2);high_candidate<=min3(hi0,hi1,hi2);
            magnitude<={1'b0,ax}+{1'b0,ay};good3<=good2;
            median_q<=good3 ? med3(low_candidate,mid_candidate,high_candidate):lp[2];
            sobel_q<=!good3 ? 8'd0:(magnitude>1020 ? 8'd255:magnitude[9:2]);
            // Two arithmetic stages implement [1 2 1;2 4 2;1 2 1]/16.
            // The color window and Sobel window end at the same pixel.
            cr0<=weighted_row(ct0[23:16],ct1[23:16],above_color2[23:16]);
            cr1<=weighted_row(cm0[23:16],cm1[23:16],above_color1[23:16]);
            cr2<=weighted_row(cb0[23:16],cb1[23:16],rp[0][23:16]);
            cg0<=weighted_row(ct0[15:8],ct1[15:8],above_color2[15:8]);
            cg1<=weighted_row(cm0[15:8],cm1[15:8],above_color1[15:8]);
            cg2<=weighted_row(cb0[15:8],cb1[15:8],rp[0][15:8]);
            cc0<=weighted_row(ct0[7:0],ct1[7:0],above_color2[7:0]);
            cc1<=weighted_row(cm0[7:0],cm1[7:0],above_color1[7:0]);
            cc2<=weighted_row(cb0[7:0],cb1[7:0],rp[0][7:0]);
            blur_r<={2'd0,cr0}+{1'b0,cr1,1'b0}+{2'd0,cr2};
            blur_g<={2'd0,cg0}+{1'b0,cg1,1'b0}+{2'd0,cg2};
            blur_b<={2'd0,cc0}+{1'b0,cc1,1'b0}+{2'd0,cc2};
            smoothed4<=!good3 ? rp[2]:{blur_r[11:4],blur_g[11:4],blur_b[11:4]};
            cartoon4<=!good3 ? quantize(rp[2]):magnitude>=148 ? 24'h181818:
                {blur_r[11:9],5'b10000,blur_g[11:9],5'b10000,blur_b[11:9],5'b10000};
        end
    end
    assign out_de=valid_pipe[3],out_x=xp[3],out_y=yp[3],original=rp[3],gray=lp[3];
    assign median=median_q,sobel=sobel_q,cartoon=cartoon4,smoothed=smoothed4;
endmodule
