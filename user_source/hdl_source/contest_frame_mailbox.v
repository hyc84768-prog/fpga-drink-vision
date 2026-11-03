// Bundled-data req/ack mailbox. Payload stays constant until the destination
// acknowledges; request synchronization plus settle cycle precedes its capture.
module contest_frame_mailbox(
    input wire source_clk,dest_clk,rst_n,submit,
    input wire [31:0] source_id,input wire source_valid,
    output reg [31:0] dest_id,output reg dest_valid
);
    reg submit_d,request,acknowledge;
    reg [32:0] held;
    reg [1:0] ack_sync,request_sync;
    reg settling;
    always @(posedge source_clk or negedge rst_n) begin
        if(!rst_n) begin submit_d<=0;request<=0;held<=0;ack_sync<=0;end
        else begin
            submit_d<=submit;ack_sync<={ack_sync[0],acknowledge};
            if(submit_d && ack_sync[1]==request) begin held<={source_valid,source_id};request<=!request;end
        end
    end
    always @(posedge dest_clk or negedge rst_n) begin
        if(!rst_n) begin request_sync<=0;acknowledge<=0;settling<=0;dest_id<=0;dest_valid<=0;end
        else begin
            request_sync<={request_sync[0],request};
            if(settling) begin dest_id<=held[31:0];dest_valid<=held[32];acknowledge<=request_sync[1];settling<=0;end
            else if(request_sync[1]!=acknowledge) settling<=1;
        end
    end
endmodule
