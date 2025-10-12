module btn_onepulse (
    input  wire clk,   // reloj del sistema
    input  wire btn,   // señal del botón (asíncrona)
    output wire pulse  // pulso de un ciclo generado al presionar el botón
);

    // -------------------------------------------------------
    // Sincronizador de 2 etapas para adaptar la señal del botón
    // al dominio de reloj
    // -------------------------------------------------------
    reg [1:0] sync = 2'b00;  

    always @(posedge clk) begin
        sync <= {sync[0], btn};  // desplaza el valor actual del botón
                                 // para conservar el estado previo y actual
    end

    // -------------------------------------------------------
    // Detección de flanco ascendente:
    // Se genera un '1' cuando la señal actual está en alto y la anterior en bajo.
    // Esto produce un pulso de UN ciclo de reloj.
    // -------------------------------------------------------
    assign pulse = sync[0] & ~sync[1];

endmodule
