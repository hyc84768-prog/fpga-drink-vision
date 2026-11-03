// Display-only branch. The classifier receives its aligned
// four-clock RGB/Sobel stream. Four additional clocks are used only by the
// algorithm group, with matching video, coordinates and logo delays.
module contest_display_enhance #(
    parameter integer WIDTH=1280,HEIGHT=720
)(
    input wire clk,rst_n,frame_start,de,
    input wire [11:0] x,y,
    input wire [7:0] median_in,
    input wire [71:0] payload,
    input wire [1:0] level,
    output wire out_de,
    output wire [11:0] out_x,out_y,
    output wire [71:0] out_payload,
    output reg [7:0] edge_out,binary_out,
    output reg [7:0] mean_luma
);
    reg [7:0] line1[0:WIDTH-1],line2[0:WIDTH-1];
    reg [7:0] line3[0:WIDTH-1],line4[0:WIDTH-1];
    reg [7:0] a1,a2,a3,a4;
    reg [7:0] w[0:4][0:3];
    reg [7:0] p[0:3];
    reg [11:0] xp[0:3],yp[0:3];
    reg [71:0] pp[0:3];
    reg [3:0] vp;
    reg [11:0] rows[0:4];
    reg [15:0] gaussian_sum;
    reg signed [11:0] gx,gy;
    wire [11:0] ax=gx[11] ? -gx:gx,ay=gy[11] ? -gy:gy;
    reg [12:0] magnitude;
    reg [7:0] center1,center2;
    reg good1,good2;
    wire [7:0] local_mean=gaussian_sum[15:8];
    wire signed [9:0] detail=$signed({2'b0,center2})-$signed({2'b0,local_mean});
    wire [9:0] abs_detail=detail[9] ? -detail:detail;
    wire [7:0] gate=level==0 ? 3:level==2 ? 8:5;
    wire [7:0] edge_threshold=level==0 ? 12:level==2 ? 32:20;
    wire [7:0] bias=level==0 ? 4:level==2 ? 12:8;
    // Noise-gated unsharp masking: gain 1.5 only on significant detail.
    wire signed [10:0] sharp=$signed({3'b0,center2})+
        (abs_detail>=gate ? (detail>>>1):11'sd0);
    wire [9:0] threshold_sum={2'b0,local_mean}+{1'b0,local_mean,1'b0}+{2'b0,mean_luma};
    wire [7:0] blended=threshold_sum[9:2];
    wire [7:0] threshold=blended>bias ? blended-bias:0;
    function [11:0] gaussian_row;
        input [7:0] a,b,c,d,e;
        begin gaussian_row={4'b0,a}+{2'b0,b,2'b0}+{1'b0,c,2'b0}+{2'b0,c,1'b0}+{2'b0,d,2'b0}+{4'b0,e};end
    endfunction
    // Independent synchronous line RAMs. Uninitialized contents are never
    // used for output in the first six rows/columns of each frame.
    always @(posedge clk)begin
        if(de && x<WIDTH)begin
            a1<=line1[x];a2<=line2[x];a3<=line3[x];a4<=line4[x];line1[x]<=median_in;
        end
        if(vp[0] && xp[0]<WIDTH)begin
            line2[xp[0]]<=a1;line3[xp[0]]<=a2;line4[xp[0]]<=a3;
        end
    end
    integer i,j;
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            vp<=0;gx<=0;gy<=0;magnitude<=0;gaussian_sum<=0;
            center1<=0;center2<=0;good1<=0;good2<=0;edge_out<=0;binary_out<=255;
            for(i=0;i<4;i=i+1)begin xp[i]<=0;yp[i]<=0;pp[i]<=0;p[i]<=0;end
            for(i=0;i<5;i=i+1)begin rows[i]<=0;for(j=0;j<4;j=j+1)w[i][j]<=0;end
        end else begin
            vp<={vp[2:0],de};xp[0]<=x;yp[0]<=y;pp[0]<=payload;p[0]<=median_in;
            for(i=1;i<4;i=i+1)begin xp[i]<=xp[i-1];yp[i]<=yp[i-1];pp[i]<=pp[i-1];p[i]<=p[i-1];end
            if(vp[0])begin
                for(i=0;i<5;i=i+1)for(j=0;j<3;j=j+1)w[i][j]<=xp[0]==0 ? 0:w[i][j+1];
                w[0][3]<=a4;w[1][3]<=a3;w[2][3]<=a2;w[3][3]<=a1;w[4][3]<=p[0];
            end
            rows[0]<=gaussian_row(w[0][0],w[0][1],w[0][2],w[0][3],a4);
            rows[1]<=gaussian_row(w[1][0],w[1][1],w[1][2],w[1][3],a3);
            rows[2]<=gaussian_row(w[2][0],w[2][1],w[2][2],w[2][3],a2);
            rows[3]<=gaussian_row(w[3][0],w[3][1],w[3][2],w[3][3],a1);
            rows[4]<=gaussian_row(w[4][0],w[4][1],w[4][2],w[4][3],p[0]);
            center1<=w[2][2];
            gx<=($signed({4'd0,w[1][3]})+($signed({4'd0,w[2][3]})<<<1)+$signed({4'd0,w[3][3]}))-
                ($signed({4'd0,w[1][1]})+($signed({4'd0,w[2][1]})<<<1)+$signed({4'd0,w[3][1]}));
            gy<=($signed({4'd0,w[3][1]})+($signed({4'd0,w[3][2]})<<<1)+$signed({4'd0,w[3][3]}))-
                ($signed({4'd0,w[1][1]})+($signed({4'd0,w[1][2]})<<<1)+$signed({4'd0,w[1][3]}));
            good1<=vp[0] && xp[0]>=6 && yp[0]>=6;
            gaussian_sum<={4'd0,rows[0]}+{2'd0,rows[1],2'd0}+{1'd0,rows[2],2'd0}+
                {2'd0,rows[2],1'd0}+{2'd0,rows[3],2'd0}+{4'd0,rows[4]};
            center2<=center1;good2<=good1;magnitude<={1'b0,ax}+{1'b0,ay};
            // Median -> Sobel -> threshold. Output is neutral, crisp white
            // contours on black, rather than amplified dim sensor gradients.
            edge_out<=good2 && magnitude>={3'd0,edge_threshold,2'd0} ? 255:0;
            // Local Gaussian illumination reference plus a quarter of the
            // frame mean preserves dark regions as well as small dark lines.
            binary_out<=!good2 ? 255:sharp<$signed({3'd0,threshold}) ? 0:255;
        end
    end
    assign out_de=vp[3],out_x=xp[3],out_y=yp[3],out_payload=pp[3];

    // Frame mean with a serial divider. No large combinational divider and
    // no new clock domain. Partial rasters do not update the brightness model.
    localparam integer PIXELS=WIDTH*HEIGHT;
    localparam integer CW=$clog2(PIXELS+1),SW=CW+8;
    reg [SW-1:0] sum,numerator;
    reg [CW-1:0] count;
    reg [CW:0] remainder;
    reg [7:0] quotient;
    reg [5:0] divide_left;
    reg mean_valid;
    wire [CW:0] trial={remainder[CW-1:0],numerator[SW-1]};
    wire take_bit=trial>=PIXELS;
    wire [7:0] next_quotient={quotient[6:0],take_bit};
    wire [9:0] mean_mix={2'b0,mean_luma}+{1'b0,mean_luma,1'b0}+{2'b0,next_quotient};
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin sum<=0;count<=0;numerator<=0;remainder<=0;quotient<=0;divide_left<=0;mean_valid<=0;mean_luma<=128;end
        else begin
            if(frame_start)begin
                if(count==PIXELS)begin numerator<=sum;remainder<=0;quotient<=0;divide_left<=SW;end
                sum<=0;count<=0;
            end else if(de)begin sum<=sum+median_in;if(count<PIXELS)count<=count+1'b1;end
            if(divide_left!=0)begin
                numerator<=numerator<<1;remainder<=take_bit ? trial-PIXELS:trial;
                quotient<=next_quotient;divide_left<=divide_left-1'b1;
                if(divide_left==1)begin mean_luma<=mean_valid ? mean_mix[9:2]:next_quotient;mean_valid<=1;end
            end
        end
    end
endmodule
