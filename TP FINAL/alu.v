`timescale 1ns/1ps
`default_nettype none

module alu #(
    parameter integer WIDTH = 32
)(
    input  wire [WIDTH-1:0] a,
    input  wire [WIDTH-1:0] b,
    input  wire  [3:0]      op,

    output reg  [WIDTH-1:0] result,
    output wire             zero,
    output wire             neg,
    output reg              carry,
    output reg              overflow
);

    localparam [3:0]
        ALU_ADD  = 4'd0,
        ALU_SUB  = 4'd1,
        ALU_AND  = 4'd2,
        ALU_OR   = 4'd3,
        ALU_XOR  = 4'd4,
        ALU_NOR  = 4'd5,
        ALU_SLL  = 4'd6,
        ALU_SRL  = 4'd7,
        ALU_SRA  = 4'd8,
        ALU_SLT  = 4'd9,
        ALU_SLTU = 4'd10;

    reg [WIDTH:0] addsub;
    wire signed [WIDTH-1:0] a_s = a;
    wire signed [WIDTH-1:0] b_s = b;
    wire [4:0] shamt = b[4:0];

    always @* begin
        result   = {WIDTH{1'b0}};
        carry    = 1'b0;
        overflow = 1'b0;
        addsub   = {(WIDTH+1){1'b0}};

        case (op)
            ALU_ADD: begin
                addsub = {1'b0, a} + {1'b0, b};
                result = addsub[WIDTH-1:0];
                carry  = addsub[WIDTH];
                overflow = (~a[WIDTH-1] & ~b[WIDTH-1] &  result[WIDTH-1]) |
                           ( a[WIDTH-1] &  b[WIDTH-1] & ~result[WIDTH-1]);
            end

            ALU_SUB: begin
                addsub = {1'b0, a} + {1'b0, ~b} + {{WIDTH{1'b0}}, 1'b1};
                result = addsub[WIDTH-1:0];
                carry  = addsub[WIDTH];
                overflow = (~a[WIDTH-1] &  b[WIDTH-1] &  result[WIDTH-1]) |
                           ( a[WIDTH-1] & ~b[WIDTH-1] & ~result[WIDTH-1]);
            end

            ALU_AND:  result = a & b;
            ALU_OR :  result = a | b;
            ALU_XOR:  result = a ^ b;
            ALU_NOR:  result = ~(a | b);

            ALU_SLL:  result = a << shamt;
            ALU_SRL:  result = a >> shamt;
            ALU_SRA:  result = $signed(a_s) >>> shamt;

            ALU_SLT:  result = (a_s < b_s) ? {{(WIDTH-1){1'b0}}, 1'b1} : {WIDTH{1'b0}};
            ALU_SLTU: result = (a < b)    ? {{(WIDTH-1){1'b0}}, 1'b1} : {WIDTH{1'b0}};

            default: begin
                result   = {WIDTH{1'b0}};
                carry    = 1'b0;
                overflow = 1'b0;
            end
        endcase
    end

    assign zero = (result == {WIDTH{1'b0}});
    assign neg  = result[WIDTH-1];

endmodule

`default_nettype wire
