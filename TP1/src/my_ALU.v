`default_nettype none

module myALU #(
    parameter integer DATA_WIDTH   = 8,  // ancho de los datos
    parameter integer OPCODE_WIDTH = 6   // ancho del código de operación
)(
    input  wire                   clk,    // reloj del sistema
    input  wire                   reset,  // reset sincrónico activo en alto
    input  wire                   e1,     // habilita la carga de A
    input  wire                   e2,     // habilita la carga de B
    input  wire                   e3,     // habilita la carga del código de operación
    input  wire [DATA_WIDTH-1:0]  data,   // entrada de datos (por switches)
    output reg  [DATA_WIDTH-1:0]  result, // salida del resultado de la ALU
    output wire                   zero,   // flag de resultado cero
    output reg                    carry,  // flag de acarreo
    output reg                    overflow, // flag de overflow
    output wire                   neg     // flag de número negativo
);

    // Registros internos para los operandos y el código de operación
    reg [DATA_WIDTH-1:0] A, B;
    reg [OPCODE_WIDTH-1:0] Op;

    // Definición de OPCODES
    localparam [OPCODE_WIDTH-1:0] OP_ADD = 6'b100000; // suma
    localparam [OPCODE_WIDTH-1:0] OP_SUB = 6'b100010; // resta
    localparam [OPCODE_WIDTH-1:0] OP_AND = 6'b100100; // AND
    localparam [OPCODE_WIDTH-1:0] OP_OR  = 6'b100101; // OR
    localparam [OPCODE_WIDTH-1:0] OP_XOR = 6'b100110; // XOR
    localparam [OPCODE_WIDTH-1:0] OP_NOR = 6'b100111; // NOR
    localparam [OPCODE_WIDTH-1:0] OP_SRL = 6'b000010; // desplazamiento lógico a la derecha
    localparam [OPCODE_WIDTH-1:0] OP_SRA = 6'b000011; // desplazamiento aritmético a la derecha

    // Cantidad de bits usados para el desplazamiento (0..7)
    localparam integer SHAMT_WIDTH = 3; 
    wire [2:0] shamt = B[SHAMT_WIDTH-1:0]; // se toma el valor de desplazamiento de los bits bajos de B

    // Variables auxiliares para suma y resta extendida (con bit extra de acarreo)
    reg [8:0] add9, sub9;

    // Registro de los operandos y del opcode
    always @(posedge clk) begin
        if (reset) begin
            A  <= 8'h00;
            B  <= 8'h00;
            Op <= OP_ADD; // valor por defecto tras el reset
        end 
        else begin
            if (e1) A  <= data;                    // captura de A
            if (e2) B  <= data;                    // captura de B
            if (e3) Op <= data[OPCODE_WIDTH-1:0];  // captura de código de operación
        end
    end

    // Bloque combinacional principal: operaciones de la ALU
    always @* begin
        result   = {DATA_WIDTH{1'b0}};
        carry    = 1'b0;
        overflow = 1'b0;

        case (Op)
            OP_ADD: begin
                add9   = {1'b0, A} + {1'b0, B};   // suma extendida
                result = add9[DATA_WIDTH-1:0];    // resultado de 8 bits
                carry  = add9[DATA_WIDTH];        // acarreo
                overflow = (~A[DATA_WIDTH-1] & ~B[DATA_WIDTH-1] &  result[DATA_WIDTH-1]) |
                           ( A[DATA_WIDTH-1] &  B[DATA_WIDTH-1] & ~result[DATA_WIDTH-1]); // detección de overflow
            end
            
            OP_SUB: begin
                sub9   = {1'b0, A} + {1'b0, ~B} + 9'd1; // resta usando complemento a dos
                result = sub9[DATA_WIDTH-1:0];
                carry  = sub9[DATA_WIDTH]; // "borrow" (préstamo)
                overflow = (~A[DATA_WIDTH-1] &  B[DATA_WIDTH-1] &  result[DATA_WIDTH-1]) |
                           ( A[DATA_WIDTH-1] & ~B[DATA_WIDTH-1] & ~result[DATA_WIDTH-1]);
            end

            OP_AND: result = A & B;             // operación lógica AND
            OP_OR : result = A | B;             // operación lógica OR
            OP_XOR: result = A ^ B;             // operación lógica XOR
            OP_NOR: result = ~(A | B);          // operación lógica NOR
            OP_SRL: result = A >>  shamt;       // desplazamiento lógico a la derecha
            OP_SRA: result = $signed(A) >>> shamt; // desplazamiento aritmético a la derecha

            default: result = {DATA_WIDTH{1'b0}}; // valor por defecto
        endcase
    end

    // Flags de estado
    assign zero = (result == {DATA_WIDTH{1'b0}}); // resultado igual a cero
    assign neg  = result[DATA_WIDTH-1];           // bit de signo (1 = negativo)

endmodule
