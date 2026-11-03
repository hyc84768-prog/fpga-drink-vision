// camera-only RAM; no phone seeds and no reset reload.
// Two groups of three 128-byte views per class, atomically selected by caller.
module bottle_template_store(input wire clk,
 input wire [10:0] seed_address, output wire [7:0] seed_data,
 input wire [11:0] read_address, output reg [7:0] read_data,
 input wire write_enable,input wire [11:0] write_address,input wire [7:0] write_data);
 reg [7:0] templates[0:3839];
 assign seed_data=8'd0;
 always @(posedge clk) begin
  read_data<=templates[read_address];
  if(write_enable) templates[write_address]<=write_data;
 end
endmodule
