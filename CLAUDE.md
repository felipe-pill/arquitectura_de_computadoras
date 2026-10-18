# Computer Architecture - Verilog projects (Basys 3 / Vivado)

## Layout
Each TP is self-contained and compiled on its own (module names repeat across TPs):
- `TPx/src/`  synthesizable RTL
- `TPx/sim/`  testbenches (`tb_*.v`)
- `TPx/constrs/`  Basys 3 constraints (.xdc)
- `TPx/py/`  host-side Python scripts (UART tests)
- `build/`  generated simulation output - never edit, never commit

Target board: Basys 3 (Artix-7, xc7a35tcpg236-1), 100 MHz clock.

## Commands (Windows, run from repo root)
- Simulate: `.\sim.bat <TP> <tb_module>`  e.g. `.\sim.bat TP2 tb_uart_loopback`
- Waveforms: `.\sim.bat <TP> <tb_module> gui`
- Always run the relevant simulation after changing RTL or a testbench,
  and don't report a task as done until it prints `SIM OK`.

## Verilog conventions
- Verilog-2001 (plain `.v`, no SystemVerilog) unless told otherwise.
- Sequential logic: `always @(posedge clk)` with non-blocking `<=` only.
- Combinational logic: `always @(*)` with blocking `=`, every output assigned
  in every branch (default assignment at the top) - no inferred latches.
- Reset: synchronous, active-high (Xilinx 7-series recommendation; Basys 3
  buttons are active-high). Never `always @(posedge clk or posedge rst)`.
  Top levels pass the reset button through a 2-FF synchronizer initialized
  to `2'b11` (so the design also resets at power-up) and distribute that.
- Use `parameter` for widths; no magic numbers.
- One module per file, file name = module name.

## Testbench conventions
- Testbenches must be self-checking: compare against expected values,
  print `PASS`/`FAIL` with inputs, expected and actual values.
- On any mismatch print a line containing `TEST FAILED`; at the end print
  `ALL TESTS PASSED` or call `$fatal`. sim.bat checks the log for these.
- End simulation with `$finish` (never run forever).
- Write tests from the spec, not by reading the RTL.

## Don'ts
- Don't modify Vivado project files (.xpr) or anything under `build/`.
- Don't change .xdc pin assignments unless asked.
