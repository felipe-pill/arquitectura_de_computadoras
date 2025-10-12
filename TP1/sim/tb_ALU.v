`timescale 1ns/1ps
`default_nettype none

module tb_alu;

  // Señales de reloj y reset
  reg clk   = 1'b0;
  reg reset = 1'b0;
  always #5 clk = ~clk;   // 100 MHz 

  // Entradas y salidas del testbench
  reg        e1 = 1'b0, e2 = 1'b0, e3 = 1'b0; // botones enable para  A, B y Op
  reg  [7:0] data = 8'h00;                    // switches de entrada para datos
  wire [7:0] result;                          // resultado de la ALU
  wire       zero, neg, carry, overflow;      // flags

  // OPCODES
  localparam [5:0] OP_ADD = 6'b100000; // suma
  localparam [5:0] OP_OR  = 6'b100101; // OR

  // Instancia del módulo
  myALU dut (
    .clk(clk), .reset(reset),
    .e1(e1), .e2(e2), .e3(e3),
    .data(data),
    .result(result), .zero(zero), .carry(carry), .overflow(overflow), .neg(neg)
  );

  // Latches de captura (pulsos de un ciclo)
  reg latched_A  = 1'b0;
  reg latched_B  = 1'b0;
  reg latched_Op = 1'b0;

  always @(posedge clk) begin
    latched_A  <= e1;     
    latched_B  <= e2;     
    latched_Op <= e3;     
  end

  // Copias de los valores cargados para comparar
  reg [7:0] A_q, B_q;
  reg [5:0] Op_q;

  always @(posedge clk) begin
    if (reset) begin
      A_q  <= 8'h00;
      B_q  <= 8'h00;
      Op_q <= OP_ADD;  // Valor por defecto tras el reset
    end else begin
      if (e1) A_q  <= data;       // Captura de A
      if (e2) B_q  <= data;       // Captura de B
      if (e3) Op_q <= data[5:0];  // Captura de OP
    end
  end

  // AUXILIARES para simplificar el test
  // Genera un pulso de un ciclo en e1, e2 o e3
  task pulse_e1; begin @(negedge clk); e1 <= 1'b1; @(posedge clk); e1 <= 1'b0; end endtask
  task pulse_e2; begin @(negedge clk); e2 <= 1'b1; @(posedge clk); e2 <= 1'b0; end endtask
  task pulse_e3; begin @(negedge clk); e3 <= 1'b1; @(posedge clk); e3 <= 1'b0; end endtask

  // Carga valores en los registros A, B y Op
  task loadA;  input [7:0] v; begin data <= v; pulse_e1(); end endtask
  task loadB;  input [7:0] v; begin data <= v; pulse_e2(); end endtask
  task loadOp; input [5:0] v; begin data <= {2'b00, v}; pulse_e3(); end endtask

  // Tarea principal: ejecuta una operación y verifica el resultado
  task do_and_check;
    input [5:0] op;
    input [7:0] a;
    input [7:0] b;
    input [7:0] exp; // resultado esperado
    begin
      // Se cargan los operandos y la operación en los registros internos
      loadA(a);
      loadB(b);
      loadOp(op);

      // Espera un ciclo para estabilizar el resultado combinacional
      @(posedge clk); #1;

      // Muestra información útil por consola
      $display("[%0t] A_q=%02h  B_q=%02h  Op_q=%06b  -> result=%02h (esperado=%02h)",
               $time, A_q, B_q, Op_q, result, exp);

      // Verificación del resultado
      if (result !== exp) begin
        $display("  *ERROR* Resultado incorrecto");
        $fatal(1);  // termina la simulación en caso de fallo
      end else begin
        $display("  OK: Resultado correcto");
      end
    end
  endtask

  // Reset del sistema
  task do_reset;
    begin
      @(negedge clk); reset <= 1'b1;
      repeat (2) @(posedge clk);
      reset <= 1'b0;
      @(posedge clk);
    end
  endtask

  // Secuencia de prueba principal
  initial begin
    // 1) Reset inicial
    do_reset();

    // 2) Prueba de suma: 15 + 27 = 42
    do_and_check(OP_ADD, 8'd15, 8'd27, 8'd42);

    // 3) Nuevo reset antes de la siguiente operación
    do_reset();

    // 4) Prueba lógica OR: A5 | 0F = AF
    do_and_check(OP_OR, 8'hA5, 8'h0F, 8'hAF);

    // Si todas las pruebas pasaron correctamente:
    $display("✅ Todas las pruebas básicas fueron exitosas.");
    $finish;
  end

endmodule
