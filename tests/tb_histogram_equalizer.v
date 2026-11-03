`timescale 1ns/1ps
module tb_histogram_equalizer;
    reg clk=0,rst_n=0,fs=0,de=0;
    reg [11:0] x=0,y=0;
    reg [7:0] luma=0;
    wire [7:0] eq;
    wire valid_map;
    integer xx,yy,i,scene,clip,excess,occupied,total,cdf,first_count,v,old_value;
    integer raw[0:255],clipped[0:255],expected[0:255];
    always #5 clk=~clk;
    contest_histogram_equalizer #(.WIDTH(16),.HEIGHT(16)) dut(clk,rst_n,fs,de,x,y,luma,eq,valid_map);
    task tick;begin @(posedge clk);#1;end endtask
    task start;begin @(negedge clk);fs=1;de=0;tick;@(negedge clk);fs=0;end endtask
    task reset;begin @(negedge clk);rst_n=0;repeat(4)tick;@(negedge clk);rst_n=1;repeat(270)tick;end endtask
    task picture;input integer pattern;
        begin
            for(i=0;i<256;i=i+1)raw[i]=0;
            for(yy=0;yy<16;yy=yy+1)begin
                for(xx=0;xx<16;xx=xx+1)begin
                    @(negedge clk);de=1;x=xx;y=yy;
                    case(pattern)
                        0:luma=xx<8 && yy<8 ? 40:(xx>=8 && yy>=8 ? 200:100);
                        1:luma=100;
                        2:luma=98+((xx/4+yy/4*4)%5);
                        3:luma=xx<8 ? 20:230;
                    endcase
                    if(xx%4==0 && yy%4==0)raw[luma]=raw[luma]+1;
                    tick;
                end
                @(negedge clk);de=0;repeat(4)tick;
            end
            repeat(8)tick;
        end
    endtask
    task reference;
        begin
            total=0;occupied=0;excess=0;clip=1;
            for(i=0;i<256;i=i+1)begin
                total=total+raw[i];if(raw[i]!=0)occupied=occupied+1;
                clipped[i]=raw[i]>clip ? clip:raw[i];excess=excess+raw[i]-clipped[i];
            end
            for(i=0;i<256;i=i+1)clipped[i]=clipped[i]+excess/256+(i<excess%256 ? 1:0);
            cdf=0;first_count=0;
            for(i=0;i<256;i=i+1)begin
                cdf=cdf+clipped[i];
                if(first_count==0 && clipped[i]!=0)first_count=cdf;
                if(occupied<=1)expected[i]=i;
                else begin
                    v=first_count==0 ? 0:((cdf-first_count)*255)/(total-first_count);
                    expected[i]=(i+v+1)/2;
                end
            end
            if(cdf!=16)$fatal(1,"reference redistribution count %0d",cdf);
        end
    endtask
    task check_value;input integer value;
        begin @(negedge clk);luma=value;de=0;repeat(4)tick;
            if(eq!==expected[value][7:0])$fatal(1,"CLHE blend %0d -> %0d expected %0d",value,eq,expected[value]);
        end
    endtask
    initial begin
        for(scene=0;scene<4;scene=scene+1)begin
            reset;start;picture(scene);reference;start;
            repeat(10000)tick;
            if(valid_map)$fatal(1,"map activated midframe");
            if(dut.cdf!=16)$fatal(1,"RTL clipping/redistribution lost sample count: %0d",dut.cdf);
            start;repeat(6)tick;
            if(!valid_map)$fatal(1,"map not activated");
            for(i=0;i<256;i=i+1)check_value(i);
            if(scene==2 && expected[102]-expected[98]>=128)$fatal(1,"narrow-range noise excessively amplified");
            // An incomplete next histogram must preserve this completed map.
            start;repeat(300)tick;check_value(100);
        end
        // A bright/dark-to-constant scene change must retain the old complete
        // LUT throughout calculation and switch to identity only at VS.
        old_value=expected[100];
        start;picture(1);reference;start;repeat(10000)tick;
        @(negedge clk);luma=100;repeat(4)tick;
        if(eq!==old_value[7:0])$fatal(1,"scene-change LUT replaced active map before boundary");
        start;repeat(6)tick;
        for(i=0;i<256;i=i+1)check_value(i);
        $display("PASS independent global CLHE clip/redistribution/CDF-min/50-percent blend reference, noise range, count conservation, constant identity, partial frames and boundary commit");$finish;
    end
    initial begin #4000000;$fatal(1,"watchdog");end
endmodule
