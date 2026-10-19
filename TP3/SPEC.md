# TP3 - 5-stage pipelined RISC-V processor + UART Debug Unit

This file is the source of truth. It restates the full course assignment
(TP3/TPFINAL.pdf, which you don't need to open). This file
restates it in full, adds clarifications from the professor, and fixes a few
errors in the slides. Where the slides and the official RISC-V spec disagree,
**follow the official RV32I spec**.

Everything already in `TP3/` (an earlier attempt) may be reused or discarded.
Starting from scratch is fine.

Reuse from earlier TPs:
- **TP1:** ALU (`TP1/src/my_ALU.v`), Basys 3 constraints.
- **TP2:** UART (`TP2/src/uart_rx.v`, `uart_tx.v`, `uart_baudgen.v`) and Python
  serial scripts (`TP2/py/`).

Copy anything reused into `TP3/` (each TP compiles on its own), then adapt it.

---

## 1. Deliverables

1. A 5-stage pipelined RV32I processor (IF, ID, EX, MEM, WB) in Verilog.
2. A Debug Unit that talks to a PC over UART: it loads programs, controls
   execution, and sends back processor state.
3. Host software (Python), consisting of:
   - an assembler from assembly to machine code;
   - an interactive CLI or TUI to load, run, step, and display state. The
     assignment asks for creativity here: make the state easy to read, for
     example by highlighting registers that changed and showing which
     instruction sits in each stage.
4. Documentation of every design decision and why, plus answers to the
   assignment's questions (section 8). Write the docs in Spanish; write code
   and comments in English.

## 2. Instructions to implement (RV32I subset)

- **R-type:** add, sub, sll, srl, sra, and, or, xor, slt, sltu
- **I-type ALU:** addi, andi, ori, xori, slti, sltiu, slli, srli, srai
- **I-type loads:** lb, lh, lw, lbu, lhu (sign- or zero-extend correctly)
- **I-type jump:** jalr. `rd = PC+4`, `PC = (rs1 + imm) & ~1`
- **S-type:** sb, sh, sw. These need byte enables on data memory.
- **B-type:** beq, bne. The offset is relative to the branch's own PC.
- **U-type:** lui
- **J-type:** jal. `rd = PC+4`, `PC = PC + imm`
- **HALT:** a stop instruction (section 5).

Corrections to the slides:
- The "J-type" slide says the jump target is stored in `rd`. That's wrong:
  `rd` receives the return address `PC+4`.
- The I-type table shows `ld`, which is RV64-only. This is a 32-bit core, so
  use `lw`.
- The `beq` encoding diagram labels both register fields `rs1`. The fields are
  `rs2` in bits [24:20] and `rs1` in bits [19:15].

General rules:
- `x0` is hardwired to zero.
- The PC is byte-addressed, increments by 4, and resets to 0.
- Misaligned accesses are out of scope; document whatever the hardware does
  with them.

## 3. Pipeline requirements

- Pipeline registers: IF/ID, ID/EX, EX/MEM, MEM/WB, as explicit modules or
  clearly named registers. The debug unit must be able to read all of them.
- Hazards, each handled and documented:
  - **Data:** forwarding from EX/MEM and MEM/WB into EX. The register file
    either writes in the first half of the cycle or bypasses internally, so
    WB-to-ID works.
  - **Load-use:** a hazard detection unit inserts a 1-cycle stall (bubble).
  - **Control:** branch and jump handling with a flush of wrongly fetched
    instructions. Choose where to resolve branches (ID with a comparator, or
    EX) and document the trade-off.
  - **Structural:** separate instruction and data memories (Harvard).
- Memory latency: Block RAM reads are synchronous, which affects how IF and
  MEM are built. Pick an approach (BRAM with the address taken from next-PC,
  distributed or async RAM, etc.) and document it.

## 4. Clock rules

- **Do not intervene in the clock anywhere.** No clock gating, no
  divided clocks, no logic on the clock path. Everything runs in one clock
  domain.
- Pausing and single-stepping use a **global enable or stall signal** that
  gates the PC, every pipeline register, register file writes, and data
  memory writes. The clock never stops.
- Deriving the system clock from the 100 MHz board clock with a Clocking
  Wizard/MMCM is allowed. That is clock generation, not intervention, and it's
  part of section 7. Put the MMCM only in the board-level top module, so
  testbenches simulate everything below it with a plain testbench clock and
  need no Xilinx IP simulation models.

## 5. Program loading and the Debug Unit

### 5.1 Reprogrammable instruction memory (critical)

The processor is general-purpose. A new program is loaded over UART at run
time, **without re-synthesizing**. Clarifications from the professor:

- The program file can be .txt, .bin, .hex, .asm, or .coe. A .coe file is
  only for following a standard. The point is that a host-side interpreter
  sends the instructions and the hardware fills instruction memory
  dynamically.
- Classmates' working approach: make instruction memory a simple dual-port
  RAM, not a ROM. Route its write address, write data, and write enable to the
  Debug Unit, and give the Debug Unit a state that writes words received over
  UART into memory. Optionally preload an example program at synthesis time
  (.coe or `$readmemh`) as a default.

Prefer inferred Block RAM written in plain Verilog over Vivado IP cores.
Inferred RAM simulates with plain `xvlog`, with no IP model compilation. The
assignment suggests looking at IP cores, so document why you chose inferred
RAM.

### 5.2 HALT

- Choose an encoding. Suggestion: use the standard `ebreak` (0x00100073), so
  other assemblers and simulators recognize it. Document the choice.
- When HALT is decoded, stop fetching new instructions and let every older
  instruction finish through WB. Only then raise `halted`. **The pipeline must
  be empty when execution ends**, in both continuous and step mode.
- Decide what happens when a program has no HALT, for example a PC that
  reaches the end of memory or a cycle timeout. Implement a safeguard and
  document it, since question 8.5 asks about this.

### 5.3 Operating modes

- **Continuous:** a UART command starts execution. It runs until HALT and the
  pipeline is drained, then all state is sent to the PC.
- **Step:** each UART command advances exactly **one clock cycle** (one
  enable pulse). State is sent after every step.

### 5.4 State sent to the PC

- all 32 registers;
- the PC;
- the contents of every pipeline register (IF/ID, ID/EX, EX/MEM, MEM/WB),
  including control signals;
- the **used** portion of data memory. Define "used", for example by
  tracking the highest address written, or a written-bit per word, and
  document it.

### 5.5 UART protocol

Design a simple, documented byte protocol on top of the TP2 UART. At minimum:
load program, run continuous, step, reset/clear, and request a state dump.
Specify framing for every command and response (command byte, length, payload,
optional checksum or acknowledgement), endianness, and the exact layout of the
state dump. The Python host and the Verilog Debug Unit must both implement
this one spec. Put it in `TP3/docs/protocol.md` before writing either side.

## 6. Host software (Python, in `TP3/py/`)

- **Assembler:** covers the full instruction subset, labels, and comments,
  plus decimal and hex immediates. Output is machine code (.hex, .bin, and
  .coe). Include unit tests that check encodings against known values from the
  RISC-V spec.
- **Reference instruction-set simulator (ISS):** a small Python model of the
  same subset. It's used to generate expected final register and memory state
  for hardware testbenches, and to cross-check the hardware state dumps.
- **CLI/TUI:** connect to the serial port, assemble and load a program, run,
  step, and show registers, PC, pipeline registers decoded into readable
  fields, and data memory. pyserial is the base; `rich` or `textual` are fine
  for a TUI.
- Example assembly programs in `TP3/asm/`, one per feature: ALU ops, loads and
  stores at every width, forwarding, load-use, branches, jal/jalr, a small
  loop, and a program without HALT.

## 7. Timing and clock (integration phase)

- Add a non-project batch build script (`TP3/scripts/build.tcl`, run with
  `vivado -mode batch -source ...`): synth, place, route, timing summary, and
  bitstream. Part: xc7a35tcpg236-1 (Basys 3).
- Find and document the **critical path** from the timing report.
- Analyze whether there is clock skew and what its consequences are.
- Find the optimal operating frequency, generate metrics with Vivado reports
  (timing, utilization), and apply that frequency via the MMCM/Clocking
  Wizard. Document the results.

## 8. Questions to answer in the documentation (in Spanish)

1. When reprogramming, does data memory need to be cleared?
2. Do the registers?
3. Does the pipeline need to be flushed?
4. Does program memory?
5. What happens if program memory contains no stop instruction?
6. What is the system's critical path?
7. Does that path generate skew? What are the consequences?
8. What is the optimal operating frequency, and how was it chosen?

## 9. Testing requirements

- Every module gets its own self-checking testbench in `TP3/sim/`, following
  the CLAUDE.md conventions (`TEST FAILED` / `ALL TESTS PASSED`).
- **CPU-level tests:** run each `asm/` program on the core testbench. Get the
  expected final registers and memory from the Python ISS, compare
  automatically, and include cycle count checks where relevant (stalls,
  flushes).
- **Debug Unit tests:** drive real serial bits into `uart_rx` from the
  testbench. Load a program, step, and run, then check the dumped bytes.
- `$readmemh` paths: simulations run inside `build/TP3/<tb>/`, so relative
  paths break. Use absolute paths passed in by the script, or adjust
  `sim.bat`, and document the fix.
- Run `.\sim.bat TP3 <tb>` after every change. A phase isn't done until all
  its testbenches pass.

## 10. Suggested phases (stop for review after each)

0. **Design:** block diagram (Mermaid in `docs/`), module list with ports,
   hazard strategy, memory strategy, HALT and drain strategy, and the UART
   protocol spec. **No RTL yet. Stop for review.**
1. Python assembler and ISS, with unit tests.
2. Datapath modules: ALU, register file, immediate generator, control,
   memories. Unit tests for each.
3. Pipeline integration without hazard handling, then forwarding, then
   load-use stall, then branch/jump flush. Add CPU-level tests at each step.
4. HALT and drain, global enable/step, and a writable instruction memory.
5. Debug Unit and UART protocol, with serial-level testbench.
6. Host CLI/TUI.
7. Board top, constraints, build script, timing analysis, MMCM frequency.
8. Final documentation and answers to section 8.
