`timescale 1ns/1ps
`default_nettype none

module myALU_top_basys3 #(
    parameter integer DATA_WIDTH = 8,  // ancho de los datos (8 bits)
    parameter integer LED_WIDTH  = 16  // cantidad de LEDs de la Basys3
)(
    input  wire        clk100,        // reloj principal de la Basys3 (100 MHz)
    input  wire [15:0] sw,            // entrada desde los switches
    input  wire        btnL,          // botón para capturar A
    input  wire        btnR,          // botón para capturar B
    input  wire        btnC,          // botón para capturar operación
    input  wire        btnU,          // reset (activo en alto)
    output wire [15:0] led            // salida hacia los LEDs
);

    // Reset: sincronizador de 2 FF para el botón (asíncrono); arranca en 1 para
    // resetear también al encender. El resto del diseño usa reset sincrónico.
    reg [1:0] rst_sync = 2'b11;
    always @(posedge clk100) begin
        rst_sync <= {rst_sync[0], btnU};
    end
    wire rst = rst_sync[1];

    // Genera pulsos de un ciclo para cada botón (sincroniza, sin antirrebote:
    // un rebote recarga el mismo valor, lo cual es inofensivo)
    wire e1_p, e2_p, e3_p;
    btn_onepulse u_p1 (.clk(clk100), .btn(btnL), .pulse(e1_p));
    btn_onepulse u_p2 (.clk(clk100), .btn(btnR), .pulse(e2_p));
    btn_onepulse u_p3 (.clk(clk100), .btn(btnC), .pulse(e3_p));

    // Señales internas
    wire [DATA_WIDTH-1:0] result;
    wire zero, neg, carry, overflow;

    // Instancia del núcleo ALU
    myALU #(
        .DATA_WIDTH(DATA_WIDTH)
    ) u_core (
        .clk      (clk100),
        .reset    (rst),
        .e1       (e1_p),
        .e2       (e2_p),
        .e3       (e3_p),
        .data     (sw[DATA_WIDTH-1:0]),  // usa los 8 switches inferiores
        .result   (result),
        .zero     (zero),
        .carry    (carry),
        .overflow (overflow),
        .neg      (neg)
    );

    // Muestra el resultado y las banderas en los LEDs
    // led = {sin uso, overflow, carry, neg, zero, result}
    localparam integer FLAG_COUNT = 4;
    localparam integer UNUSED     = LED_WIDTH - DATA_WIDTH - FLAG_COUNT;

    assign led = {{UNUSED{1'b0}}, overflow, carry, neg, zero, result};

endmodule

`default_nettype wire
