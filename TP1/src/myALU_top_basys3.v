module myALU_top_basys3 #(  
    parameter integer DATA_WIDTH = 8  // ancho de los datos (8 bits)
)(
    input  wire        clk100,        // reloj principal de la Basys3 (100 MHz)
    input  wire [15:0] sw,            // entrada desde los switches
    input  wire        btnL,          // botón para capturar A
    input  wire        btnR,          // botón para capturar B
    input  wire        btnC,          // botón para capturar operación
    input  wire        btnU,          // reset (activo en alto)
    output wire [15:0] led            // salida hacia los LEDs
);

    // Genera pulsos de un ciclo para cada botón (evita rebotes)
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
        .reset    (btnU),
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
    assign led[DATA_WIDTH-1:0] = result;  // resultado en los LEDs bajos
    assign led[DATA_WIDTH]     = zero;    // flag de cero
    assign led[9]              = neg;     // flag de negativo
    assign led[10]             = carry;   // flag de acarreo
    assign led[11]             = overflow;// flag de overflow
    assign led[15:12]          = 4'b0;    // LEDs sin uso

endmodule
