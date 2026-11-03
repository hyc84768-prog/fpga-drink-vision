// Sampled full-frame global contrast-limited histogram equalization (CLHE).
// Clip to ceil(2*N/256), redistribute all excess with count conservation,
// then CDF-min equalize and blend 50% with the original luminance.
// One shared 24-step integer divider, never a per-pixel division. A completed
// map is activated only at frame_start. Collection resumes on a full boundary.
module contest_histogram_equalizer #(
    parameter integer WIDTH=1280,HEIGHT=720
)(input wire clk,rst_n,frame_start,de,
  input wire [11:0] x,y,input wire [7:0] luma,
  output wire [7:0] equalized,output reg map_valid);
    localparam integer EXPECTED=((WIDTH+3)/4)*((HEIGHT+3)/4);
    localparam integer CLIP_LIMIT=(EXPECTED+127)/128;
    localparam CLEAR=0,READY=1,COLLECT=2,CLIP_READ=3,CLIP_WAIT=4,CLIP_WRITE=5,
               READ=6,WAIT=7,PREP=8,DIVIDE=9,WRITE=10;
    reg [3:0] state;
    reg [15:0] histogram[0:255];
    reg [7:0] maps[0:511];
    reg [7:0] bin,sample_bin,count_luma;
    reg [15:0] count_q,sample_count,total,cdf,cdf_min,denominator;
    reg [15:0] excess;
    reg [1:0] occupied;
    reg sample_pending,first_seen,active_bank,pending_map;
    reg pending_identity,active_identity;
    reg [23:0] numerator,quotient;
    reg [16:0] remainder;
    reg [4:0] divide_count;
    reg [7:0] map_value;
    wire sample=state==COLLECT && de && x<WIDTH && y<HEIGHT && x[1:0]==0 && y[1:0]==0;
    wire [16:0] redistributed_count={1'b0,count_q}+{9'd0,excess[15:8]}+
        (bin<excess[7:0] ? 17'd1:17'd0);
    wire [16:0] next_cdf={1'b0,cdf}+redistributed_count;
    wire [1:0] occupied_next=count_q!=0 && occupied<2 ? occupied+1'b1:occupied;
    wire [16:0] trial={remainder[15:0],numerator[23]};
    reg [7:0] mapped[0:3],plain[0:3];
    reg [3:0] valid_map_pipe;
    integer i;
    always @(posedge clk) begin
        if(state==CLEAR) histogram[bin]<=0;
        else if(state==COLLECT && sample_pending) histogram[sample_bin]<=sample_count+1'b1;
        else if(state==CLIP_WRITE) histogram[bin]<=count_q>CLIP_LIMIT ? CLIP_LIMIT:count_q;
        if(sample) count_luma<=luma;
        if(sample) sample_count<=histogram[luma];
        if(state==READ || state==CLIP_READ) count_q<=histogram[bin];
        if(state==WRITE) maps[{!active_bank,bin}]<=map_value;
        mapped[0]<=maps[{active_bank,luma}];
        for(i=1;i<4;i=i+1) mapped[i]<=mapped[i-1];
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=CLEAR;bin<=0;sample_bin<=0;sample_pending<=0;total<=0;cdf<=0;cdf_min<=0;
            first_seen<=0;active_bank<=0;pending_map<=0;map_valid<=0;denominator<=0;
            numerator<=0;quotient<=0;remainder<=0;divide_count<=0;map_value<=0;
            valid_map_pipe<=0;
            pending_identity<=0;active_identity<=0;
            excess<=0;occupied<=0;
            for(i=0;i<4;i=i+1) plain[i]<=0;
        end else begin
            plain[0]<=luma;for(i=1;i<4;i=i+1) plain[i]<=plain[i-1];
            valid_map_pipe<={valid_map_pipe[2:0],map_valid && !active_identity};
            sample_pending<=sample;
            if(sample) begin sample_bin<=luma;total<=total+1'b1;end
            case(state)
                CLEAR: if(bin==255) begin bin<=0;state<=READY;end else bin<=bin+1'b1;
                READY: if(frame_start) begin
                    if(pending_map) begin active_bank<=!active_bank;active_identity<=pending_identity;map_valid<=1;pending_map<=0;end
                    total<=0;state<=COLLECT;
                end
                COLLECT: if(frame_start) begin
                    bin<=0;cdf<=0;cdf_min<=0;first_seen<=0;pending_identity<=0;
                    excess<=0;occupied<=0;
                    state<=total==EXPECTED ? CLIP_READ:CLEAR;
                end
                CLIP_READ: state<=CLIP_WAIT;
                CLIP_WAIT: state<=CLIP_WRITE;
                CLIP_WRITE: begin
                    if(count_q>CLIP_LIMIT) excess<=excess+(count_q-CLIP_LIMIT);
                    occupied<=occupied_next;
                    if(bin==255) begin
                        pending_identity<=occupied_next<=1;
                        bin<=0;state<=READ;
                    end else begin bin<=bin+1'b1;state<=CLIP_READ;end
                end
                READ: state<=WAIT;
                WAIT: state<=PREP;
                PREP: begin
                    cdf<=next_cdf[15:0];
                    if(pending_identity) begin map_value<=bin;state<=WRITE;end
                    else if(!first_seen) begin
                        map_value<=0;state<=WRITE;
                        if(redistributed_count!=0) begin
                            first_seen<=1;cdf_min<=next_cdf[15:0];
                            if(next_cdf==total) begin map_value<=bin;pending_identity<=1;end
                        end
                    end else if(total==cdf_min) begin map_value<=bin;state<=WRITE;end
                    else begin
                        numerator<=((next_cdf[15:0]-cdf_min)<<8)-(next_cdf[15:0]-cdf_min);
                        denominator<=total-cdf_min;remainder<=0;quotient<=0;divide_count<=24;state<=DIVIDE;
                    end
                end
                DIVIDE: begin
                    numerator<={numerator[22:0],1'b0};
                    remainder<=trial>=denominator ? trial-denominator:trial;
                    quotient<={quotient[22:0],trial>=denominator};
                    divide_count<=divide_count-1'b1;
                    if(divide_count==1) begin map_value<={quotient[6:0],trial>=denominator};state<=WRITE;end
                end
                WRITE: if(bin==255) begin pending_map<=1;bin<=0;state<=CLEAR;end
                       else begin bin<=bin+1'b1;state<=READ;end
                default: state<=CLEAR;
            endcase
        end
    end
    wire [8:0] mixed={1'b0,mapped[3]}+{1'b0,plain[3]}+9'd1;
    assign equalized=valid_map_pipe[3] ? mixed[8:1]:plain[3];
endmodule
