`timescale 1ns/1ps
module tb_spatial_filters;
    reg clk=0,rst_n=0,de=0;
    reg [11:0] x=0,y=0;
    reg [23:0] rgb=0;
    wire od;
    wire [11:0] ox,oy;
    wire [23:0] original,cartoon,smoothed;
    wire [7:0] gray,median,sobel;
    integer image[0:191],v[0:8];
    reg [23:0] color_image[0:191];
    integer xx,yy,f,i,j,n,tmp,gx,gy,m,expected,checked=0;
    integer c,blur,expected_cart,expected_smoothed,w,red,green,blue;
    always #5 clk=~clk;
    contest_spatial_filters #(.WIDTH(16)) dut(clk,rst_n,de,x,y,rgb,od,ox,oy,original,cartoon,gray,median,sobel,smoothed);
    always @(posedge clk) begin
        #1;
        if(rst_n && od) begin
            if(original!==color_image[oy*16+ox] || gray!==image[oy*16+ox])
                $fatal(1,"original/coordinate latency mismatch at %0d,%0d",ox,oy);
            expected=image[oy*16+ox];m=0;
            if(ox>=2 && oy>=2) begin
                n=0;
                for(i=-2;i<=0;i=i+1) for(j=-2;j<=0;j=j+1) begin v[n]=image[(oy+i)*16+ox+j];n=n+1;end
                gx=v[2]+2*v[5]+v[8]-v[0]-2*v[3]-v[6];
                gy=v[6]+2*v[7]+v[8]-v[0]-2*v[1]-v[2];
                m=((gx<0 ? -gx:gx)+(gy<0 ? -gy:gy))/4;if(m>255)m=255;
                for(i=0;i<9;i=i+1) for(j=i+1;j<9;j=j+1)
                    if(v[i]>v[j])begin tmp=v[i];v[i]=v[j];v[j]=tmp;end
                expected=v[4];
            end
            if(median!==expected || sobel!==m)
                $fatal(1,"3x3 kernel mismatch at %0d,%0d median %0d/%0d sobel %0d/%0d",ox,oy,median,expected,sobel,m);
            expected_cart=0;expected_smoothed=0;
            for(c=0;c<3;c=c+1) begin
                if(ox<2 || oy<2) blur=(color_image[oy*16+ox]>>(c*8))&255;
                else begin
                    blur=0;
                    for(i=-2;i<=0;i=i+1) for(j=-2;j<=0;j=j+1) begin
                        w=(i==-1 ? 2:1)*(j==-1 ? 2:1);
                        blur=blur+w*((color_image[(oy+i)*16+ox+j]>>(c*8))&255);
                    end
                    blur=blur/16;
                end
                expected_smoothed=expected_smoothed|(blur<<(c*8));
                expected_cart=expected_cart|(((blur&224)|16)<<(c*8));
            end
            if(ox>=2 && oy>=2 && m>36) expected_cart=24'h181818;
            if(smoothed!==expected_smoothed[23:0])
                $fatal(1,"unquantized RGB smoothing mismatch at %0d,%0d: %h/%h",ox,oy,smoothed,expected_smoothed[23:0]);
            if(cartoon!==expected_cart[23:0])
                $fatal(1,"RGB binomial cartoon/edge mismatch at %0d,%0d: %h/%h",ox,oy,cartoon,expected_cart[23:0]);
            checked=checked+1;
        end
    end
    initial begin
        repeat(5) @(negedge clk);rst_n=1;
        for(f=0;f<8;f=f+1) begin
            for(i=0;i<192;i=i+1)begin
                case(f)
                    0:image[i]=(i*73+i/16*31)%256;
                    1:image[i]=i%16<8 ? 20:220;
                    2:image[i]=i/16<6 ? 20:220;
                    3:image[i]=(i==101) ? 255:96;
                    default:image[i]=0;
                endcase
                if(f<4) color_image[i]={3{image[i][7:0]}};
                else begin
                    case(f)
                        4:begin red=(i%16)*17;green=(i/16)*23;blue=(i*53)%256;end
                        5:begin red=64+(i*7)%5;green=96+(i*11)%5;blue=128+(i*13)%5;end
                        6:begin red=(i%2)^((i/16)%2) ? 224:32;green=255-red;blue=80;end
                        7:begin red=240;green=32;blue=144;end
                    endcase
                    color_image[i]={red[7:0],green[7:0],blue[7:0]};
                    image[i]=(red+2*green+blue)/4;
                end
            end
            for(yy=0;yy<12;yy=yy+1)begin
                for(xx=0;xx<16;xx=xx+1)begin
                    @(negedge clk);de=1;x=xx;y=yy;rgb=color_image[yy*16+xx];
                end
                @(negedge clk);de=0;repeat(5) @(negedge clk);
            end
            repeat(8) @(negedge clk);
        end
        if(checked!=1536)$fatal(1,"missing kernel samples %0d",checked);
        $display("PASS independent 3x3 median/Sobel, unquantized RGB smoothing and cartoon references: impulses, steps, RGB ramps/checkers/noise/constant, borders and four-clock latency");$finish;
    end
endmodule
