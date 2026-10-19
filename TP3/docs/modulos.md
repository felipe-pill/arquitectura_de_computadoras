# TP3 - Módulos y puertos

Estado: **Fase 0 (diseño) - revisado**. Los nombres y anchos son el
contrato para las fases 2-5. Los submódulos de la Debug Unit (sección 4)
pueden ajustarse en la fase 5 sin cambiar protocol.md.

Convenciones (CLAUDE.md):
- un módulo por archivo, nombre de archivo = nombre del módulo;
- Verilog-2001;
- reset síncrono activo en alto (`rst`);
- anchos por `parameter`;
- todos los elementos secuenciales del core siguen el patrón
  `if (rst) ... else if (en) ...`.

## 1. Jerarquía

```
basys3_top                      (solo placa: MMCM, sincronizador de reset, pines)
└── system_top                  (tope de los testbenches de sistema)
    ├── uart                    (TP2, sin cambios)
    │   ├── uart_baudgen
    │   ├── uart_rx
    │   └── uart_tx
    ├── debug_unit
    │   ├── dbg_rx_frame        (parser de tramas, checksum, timeout entre bytes)
    │   ├── dbg_tx_frame        (armado de tramas de respuesta)
    │   ├── dbg_state_src       (genera los bytes del volcado de estado)
    │   └── dbg_ctrl            (FSM de comandos)
    ├── cpu_core
    │   ├── fetch_unit          (PC + mux de next_pc + stop_code)
    │   ├── if_id_reg
    │   ├── decoder
    │   ├── imm_gen
    │   ├── regfile
    │   ├── hazard_unit
    │   ├── id_ex_reg
    │   ├── forward_unit
    │   ├── alu
    │   ├── branch_unit
    │   ├── store_align
    │   ├── ex_mem_reg
    │   ├── load_align
    │   ├── mem_wb_reg
    │   └── halt_ctrl           (halting/halted/motivo + cycle_cnt/timeout)
    ├── imem                    (BRAM inferida, simple dual port)
    └── dmem                    (BRAM inferida, true dual port, B solo lectura)
```

Las memorias quedan **fuera** de `cpu_core`. Así los tests a nivel CPU (fase 3)
instancian `cpu_core + imem + dmem` con `$readmemh`, sin UART. El mux del
puerto A de dmem (core o borrado de la Debug Unit) es un `assign` en
`system_top`.

## 2. Tope y memorias

### `basys3_top`
| Puerto | Dir | Ancho | Descripción |
|---|---|---|---|
| `clk100mhz` | in | 1 | reloj de placa (W5) |
| `btn_reset` | in | 1 | botón central (U18), activo en alto |
| `uart_rxd` | in | 1 | USB-UART PC → FPGA (B18) |
| `uart_txd` | out | 1 | FPGA → PC (A18) |
| `led` | out | 16 | `[0]` running, `[1]` halting, `[2]` halted, `[5:3]` halt_reason, resto 0 |

Contiene: MMCM (fase 7; se prefiere la primitiva `MMCME2_BASE` instanciada
directamente, sin `.xci`) y el sincronizador 2FF con init `2'b11`. Su reset
es `btn_reset | !mmcm_locked`.

### `system_top`
Parámetros: `CLK_FREQ_HZ`, `BAUD`, `IMEM_ADDR_W`, `DMEM_ADDR_W`,
`IMEM_INIT_FILE`, `IMEM_INIT_LEN`, `MAX_CYCLES`.

| Puerto | Dir | Ancho | Descripción |
|---|---|---|---|
| `clk` | in | 1 | reloj del sistema |
| `rst` | in | 1 | reset síncrono ya sincronizado |
| `uart_rxd` | in | 1 | línea serie de entrada |
| `uart_txd` | out | 1 | línea serie de salida |
| `running`, `halting`, `halted` | out | 1 c/u | para LEDs |
| `halt_reason` | out | 3 | para LEDs |

### `imem` - parámetros `ADDR_W`, `INIT_FILE`
| Puerto | Dir | Ancho | Descripción |
|---|---|---|---|
| `clk` | in | 1 | |
| `we` | in | 1 | escritura (Debug Unit) |
| `waddr` | in | `ADDR_W` | dirección de palabra |
| `wdata` | in | 32 | |
| `raddr` | in | `ADDR_W` | dirección de lectura (`next_pc[ADDR_W+1:2]`) |
| `rdata` | out | 32 | registrada (lectura síncrona) |

### `dmem` - parámetro `ADDR_W`
| Puerto | Dir | Ancho | Descripción |
|---|---|---|---|
| `clk` | in | 1 | |
| `a_en` | in | 1 | enable del puerto A (mantiene `a_rdata` si vale 0) |
| `a_we` | in | 4 | byte enables de escritura |
| `a_addr` | in | `ADDR_W` | dirección de palabra |
| `a_wdata` | in | 32 | |
| `a_rdata` | out | 32 | registrada |
| `b_addr` | in | `ADDR_W` | puerto de lectura de la Debug Unit |
| `b_rdata` | out | 32 | registrada |

## 3. `cpu_core`

Parámetros: `IMEM_ADDR_W`, `DMEM_ADDR_W`, `MAX_CYCLES`.

| Puerto | Dir | Ancho | Descripción |
|---|---|---|---|
| `clk` | in | 1 | |
| `rst` | in | 1 | `core_rst` de la Debug Unit |
| `en` | in | 1 | enable global (run o pulso de step) |
| `imem_limit` | in | `IMEM_ADDR_W+1` | `prog_len` en palabras (para OOR) |
| `imem_addr` | out | `IMEM_ADDR_W` | `next_pc[IMEM_ADDR_W+1:2]` |
| `imem_rdata` | in | 32 | |
| `dmem_en` | out | 1 | `= en_int` |
| `dmem_we` | out | 4 | byte enables, ya con `en_int` |
| `dmem_addr` | out | `DMEM_ADDR_W` | resultado de la ALU en EX, `[DMEM_ADDR_W+1:2]` |
| `dmem_wdata` | out | 32 | dato del store, alineado al carril |
| `dmem_rdata` | in | 32 | |
| `halting` | out | 1 | HALT aceptado, drenando |
| `halted` | out | 1 | pipeline vacío, ejecución terminada |
| `halt_reason` | out | 3 | |
| `cycle_cnt` | out | 32 | ciclos habilitados desde reset |
| `dbg_reg_addr` | in | 5 | puerto de lectura de debug del banco |
| `dbg_reg_data` | out | 32 | |
| `dbg_core_vec` | out | 512 | PC + registros de pipeline (protocol.md §6.2) |

Lógica "suelta" dentro de `cpu_core` (no amerita módulo propio):
- `en_int = en & ~halted`;
- muxes de forwarding;
- `ex_result = link ? pc+4 : alu_y`;
- sumador `if_id.pc + imm_J` para jal;
- `wb_data = mem_read ? load_data : ex_mem.result`.

### `fetch_unit` - parámetro `IMEM_ADDR_W`
| Puerto | Dir | Ancho | Descripción |
|---|---|---|---|
| `clk`, `rst`, `en` | in | 1 | `en` = `en_int` |
| `ex_redirect` | in | 1 | salto tomado o jalr en EX |
| `ex_target` | in | 32 | |
| `halt_accept` | in | 1 | |
| `halt_pc` | in | 32 | `if_id.pc` |
| `halting` | in | 1 | |
| `load_use` | in | 1 | |
| `id_jal` | in | 1 | jal válido en ID |
| `id_jal_target` | in | 32 | |
| `timeout` | in | 1 | de `halt_ctrl` (`cycle_cnt >= MAX_CYCLES`) |
| `imem_limit` | in | `IMEM_ADDR_W+1` | |
| `pc` | out | 32 | PC de la instrucción en IF |
| `imem_addr` | out | `IMEM_ADDR_W` | de `next_pc` |
| `fetch_stop_code` | out | 3 | TIMEOUT si `timeout`; si no, OOR si `pc >= 4*imem_limit`; si no, 0 |

### `if_id_reg`
| Puerto | Dir | Ancho | Descripción |
|---|---|---|---|
| `clk`, `rst`, `en` | in | 1 | |
| `flush` | in | 1 | carga burbuja; prioridad sobre `hold` |
| `hold` | in | 1 | mantiene (load-use) |
| `in_pc`, `in_instr` | in | 32 c/u | |
| `in_stop_code` | in | 3 | |
| `pc`, `instr` | out | 32 c/u | burbuja: `instr = 0x00000013` (NOP) |
| `stop_code` | out | 3 | |
| `valid` | out | 1 | 0 = burbuja |

`flush = ex_redirect | halt_accept | halting | id_jal`, `hold = load_use`.
Como la burbuja lleva una NOP real, el decoder no necesita mirar `valid`.

### `decoder`
| Puerto | Dir | Ancho | Descripción |
|---|---|---|---|
| `instr` | in | 32 | |
| `stop_code` | in | 3 | |
| `rs1`, `rs2`, `rd` | out | 5 c/u | rs efectivos (0 si no se usan) |
| `alu_op` | out | 4 | `{alt, funct3}` |
| `alu_src`, `link`, `reg_write`, `mem_read`, `mem_write` | out | 1 c/u | |
| `funct3` | out | 3 | |
| `branch`, `jalr`, `jal` | out | 1 c/u | |
| `imm_sel` | out | 3 | I, S, B, U, J |
| `halt_cond` | out | 1 | `stop_code != 0`, `ebreak` o ilegal; anula todo el control |
| `halt_reason` | out | 3 | prioridad `stop_code` > HALT > ILLEGAL |

### `imm_gen`
| Puerto | Dir | Ancho |
|---|---|---|
| `instr` | in | 32 |
| `imm_sel` | in | 3 |
| `imm` | out | 32 |

### `regfile`
| Puerto | Dir | Ancho | Descripción |
|---|---|---|---|
| `clk`, `rst` | in | 1 | `rst` pone x1..x31 en 0 |
| `we` | in | 1 | `en_int & mem_wb.reg_write` |
| `waddr` | in | 5 | ignora `waddr = 0` |
| `wdata` | in | 32 | |
| `raddr1`, `raddr2` | in | 5 c/u | |
| `rdata1`, `rdata2` | out | 32 c/u | asíncronas, con bypass interno de la escritura |
| `dbg_addr` | in | 5 | |
| `dbg_data` | out | 32 | asíncrona, sin bypass (el core está congelado) |

### `hazard_unit`
| Puerto | Dir | Ancho |
|---|---|---|
| `if_id_valid` | in | 1 |
| `id_rs1`, `id_rs2` | in | 5 c/u |
| `id_ex_mem_read` | in | 1 |
| `id_ex_rd` | in | 5 |
| `load_use` | out | 1 |

### `id_ex_reg`
| Puerto | Dir | Ancho | Descripción |
|---|---|---|---|
| `clk`, `rst`, `en` | in | 1 | |
| `flush` | in | 1 | `ex_redirect | load_use` → burbuja |
| `in_*` / salidas | | | `pc`(32), `rs1_data`(32), `rs2_data`(32), `imm`(32), `rs1`(5), `rs2`(5), `rd`(5), `alu_op`(4), `alu_src`, `link`, `reg_write`, `mem_read`, `mem_write`, `funct3`(3), `branch`, `jalr`, `is_halt`, `valid` |

`in_is_halt = halt_cond`. Cuando el slot es un HALT aceptado, el decoder ya
anuló el resto del control, así que entra el marcador HALT.

### `forward_unit`
| Puerto | Dir | Ancho | Descripción |
|---|---|---|---|
| `id_ex_rs1`, `id_ex_rs2` | in | 5 c/u | |
| `ex_mem_rd`, `ex_mem_reg_write`, `ex_mem_mem_read` | in | 5/1/1 | |
| `mem_wb_rd`, `mem_wb_reg_write` | in | 5/1 | |
| `fwd_a`, `fwd_b` | out | 2 c/u | `00` banco, `10` EX/MEM, `01` MEM/WB |

### `alu`
| Puerto | Dir | Ancho |
|---|---|---|
| `a`, `b` | in | 32 c/u |
| `op` | in | 4 |
| `y` | out | 32 |

Sin flags: el branch usa un comparador propio.

### `branch_unit`
| Puerto | Dir | Ancho | Descripción |
|---|---|---|---|
| `valid`, `branch`, `jalr` | in | 1 c/u | |
| `is_bne` | in | 1 | `funct3[0]` |
| `rs1_val`, `rs2_val` | in | 32 c/u | ya forwardeados |
| `pc`, `imm` | in | 32 c/u | |
| `alu_y` | in | 32 | `rs1 + imm` para jalr |
| `redirect` | out | 1 | |
| `target` | out | 32 | `jalr ? alu_y & ~1 : pc + imm` |

### `store_align`
| Puerto | Dir | Ancho |
|---|---|---|
| `funct3` | in | 2 (`[1:0]`) |
| `addr_lo` | in | 2 |
| `data` | in | 32 |
| `wdata` | out | 32 |
| `be` | out | 4 |

### `ex_mem_reg`
| Puerto | Dir | Ancho | Descripción |
|---|---|---|---|
| `clk`, `rst`, `en` | in | 1 | |
| `in_*` / salidas | | | `pc`(32), `result`(32), `store_data`(32, rs2 sin alinear, para mostrar), `rd`(5), `reg_write`, `mem_read`, `mem_write`, `funct3`(3), `is_halt`, `valid` |

### `load_align`
| Puerto | Dir | Ancho |
|---|---|---|
| `funct3` | in | 3 |
| `addr_lo` | in | 2 |
| `rdata` | in | 32 |
| `data` | out | 32 |

### `mem_wb_reg`
| Puerto | Dir | Ancho | Descripción |
|---|---|---|---|
| `clk`, `rst`, `en` | in | 1 | |
| `in_*` / salidas | | | `pc`(32), `wb_data`(32), `rd`(5), `reg_write`, `mem_read`, `is_halt`, `valid` |

### `halt_ctrl`
| Puerto | Dir | Ancho | Descripción |
|---|---|---|---|
| `clk`, `rst`, `en` | in | 1 | `en` = `en_int` |
| `halt_accept` | in | 1 | |
| `halt_reason_in` | in | 3 | |
| `wb_halt` | in | 1 | `mem_wb.valid & mem_wb.is_halt` |
| `halting`, `halted` | out | 1 c/u | |
| `halt_reason` | out | 3 | |
| `cycle_cnt` | out | 32 | |
| `timeout` | out | 1 | `cycle_cnt >= MAX_CYCLES` |

## 4. `debug_unit`

Parámetros: `CLK_FREQ_HZ`, `IMEM_ADDR_W`, `DMEM_ADDR_W`,
`RX_TIMEOUT_CYCLES` (= `CLK_FREQ_HZ/100`, 10 ms).

| Puerto | Dir | Ancho | Descripción |
|---|---|---|---|
| `clk`, `rst` | in | 1 | |
| `rx_data` | in | 8 | desde `uart` |
| `rx_valid`, `rx_ferr` | in | 1 c/u | |
| `tx_start` | out | 1 | |
| `tx_data` | out | 8 | |
| `tx_busy` | in | 1 | |
| `core_rst`, `core_en` | out | 1 c/u | |
| `imem_limit` | out | `IMEM_ADDR_W+1` | `prog_len` |
| `halted`, `halting` | in | 1 c/u | |
| `halt_reason` | in | 3 | |
| `cycle_cnt` | in | 32 | |
| `dbg_core_vec` | in | 512 | |
| `dbg_reg_addr` | out | 5 | |
| `dbg_reg_data` | in | 32 | |
| `imem_we` | out | 1 | |
| `imem_waddr` | out | `IMEM_ADDR_W` | |
| `imem_wdata` | out | 32 | |
| `dmem_clr` | out | 1 | toma el puerto A (solo con `core_rst = 1`) |
| `dmem_clr_addr` | out | `DMEM_ADDR_W` | con `we = 4'hF` y `wdata = 0` |
| `cpu_dmem_we` | in | 4 | espía del puerto A (high-water mark) |
| `cpu_dmem_addr` | in | `DMEM_ADDR_W` | |
| `dmem_b_addr` | out | `DMEM_ADDR_W` | |
| `dmem_b_rdata` | in | 32 | |
| `running` | out | 1 | para LEDs |

Submódulos (las interfaces internas pueden refinarse en la fase 5):

- **`dbg_rx_frame`**: busca el SOF `0xA5`, lee CMD y LEN, entrega el payload
  byte a byte (`pl_valid`, `pl_byte`) y al final informa `frame_end` y
  `frame_ok` (checksum).
  - Aborta en silencio si pasan `RX_TIMEOUT_CYCLES` sin bytes a mitad de
    trama o si llega un byte con `rx_ferr`.
  - También entrega `hdr_valid`, `hdr_cmd` y `hdr_len` apenas termina el
    encabezado, para que LOAD pueda escribir en imem mientras llegan los
    bytes.
- **`dbg_tx_frame`**: con `start`, `rsp_code` y `rsp_len`, envía SOF `0x5A`,
  código, LEN, el payload y el checksum.
  - Pide cada byte del payload a una fuente con `src_req`/`src_idx` y espera
    `src_valid`/`src_byte` (latencia variable: la dmem tarda 1 ciclo).
  - Respeta que `tx_busy` sube un ciclo después de `tx_start`.
- **`dbg_state_src`**: según el modo (STATE o payload corto), traduce
  `src_idx` al byte correspondiente. Lee el bloque de estado, `dbg_core_vec`,
  el banco (`dbg_reg_addr`) y la dmem (`dmem_b_addr`).
- **`dbg_ctrl`**: FSM de comandos, con estados IDLE, LOAD, RESET (barrido de
  borrado), RUN, STEP y SEND.
  - Maneja `core_rst`, `core_en`, `prog_len`, `prog_valid` y `dmem_used`.
  - Durante RUN no atiende comandos: las tramas que llegan se descartan.
  - Valida estado y longitud y elige el código de respuesta.

## 5. Testbenches previstos (`TP3/sim/`)

Uno por módulo (`tb_alu`, `tb_regfile`, `tb_imm_gen`, `tb_decoder`,
`tb_load_align`, `tb_store_align`, `tb_imem`, `tb_dmem`, `tb_forward_unit`,
`tb_hazard_unit`, `tb_branch_unit`, ...), más:
- `tb_cpu_core`: corre cada programa de `asm/`, compara con el resultado del
  ISS y verifica la cantidad de ciclos;
- `tb_debug_unit` / `tb_system_top`: tramas serie reales, verifica los bytes
  del volcado.
