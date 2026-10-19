# TP3 - Verificación (simulación)

Estado: **Fase 3 terminada**. El core completo (`cpu_core`) y cada uno de sus
módulos tienen testbench, y todos dan `SIM OK`.

## 1. Cómo se corre

Desde la raíz del repo:

```
.\sim.bat TP3 <testbench>          # por ejemplo: .\sim.bat TP3 tb_cpu_core
.\sim.bat TP3 <testbench> gui      # con formas de onda
python -m unittest discover -s TP3/py -v    # tests de Python (fase 1)
```

Cada testbench es autoverificable, según CLAUDE.md:
- imprime `PASS`/`FAIL` con entradas, valor esperado y valor obtenido;
- ante cualquier diferencia imprime una línea con `TEST FAILED`;
- al final imprime `ALL TESTS PASSED (...)` o llama a `$fatal`.

`sim.bat` informa `SIM OK` solo si no hubo `TEST FAILED` ni `Fatal`.

## 2. Archivos de datos y `$readmemh` (SPEC §9)

**Problema:** xsim corre dentro de `build/TP3/<tb>/`, así que una ruta
relativa como `"../sim/data/x.hex"` depende de dónde se ejecute, y una ruta
absoluta depende de la máquina.

**Solución:** `sim.bat` tiene un paso opcional de *pre-build*. Si existe
`<TP>\sim\prebuild.bat`, lo llama antes de compilar, con el directorio de
build y el nombre del testbench. El de TP3 hace dos cosas:

1. copia `TP3/sim/data/*.hex` (datos fijos de prueba, por ejemplo
   `imem_init.hex`) al directorio de build;
2. corre `python TP3/py/gen_vectors.py <build>`, que genera
   `isa_vectors.hex` (§3.1) y `cpu_tests.hex` (§4.2).

Así los testbenches abren los archivos **por nombre simple**
(`$readmemh("isa_vectors.hex", ...)`), y los archivos generados nunca quedan
en el repo: `build/` está en `.gitignore`.

**Alternativas:**
- pasar rutas absolutas con `xelab -generic_top` o `xvlog -d`: el escapado
  de comillas en un `.bat` es frágil y las rutas tienen espacios;
- generar los vectores a mano antes de simular: es fácil olvidarse, y
  `sim.bat` no lo detecta.

El cambio en `sim.bat` no afecta a TP1/TP2, que no tienen `prebuild.bat`.
Requiere `python` en el PATH.

## 3. Fase 2: módulos del datapath

| Testbench | Módulo | Qué verifica | Checks |
|---|---|---|---|
| `tb_alu` | `alu` | 25 casos dirigidos (overflow, signo, shift por `b[4:0]`, `srai` con imm 0x401, ops inválidas = 0) y 2000 aleatorios por operación contra un modelo de la especificación | 20 025 |
| `tb_regfile` | `regfile` | reset, escritura y lectura de los 32 registros, x0 ignora escrituras, bypass en el mismo ciclo en los dos puertos (no en el de debug), `we = 0`, reset con prioridad sobre la escritura, 3000 ciclos aleatorios contra un modelo | 9 275 |
| `tb_imm_gen` | `imm_gen` | 11 inmediatos conocidos (I/S/B/U/J con extremos), `imm_sel` 5..7 = 0, los ~3300 vectores de Python y además todos los formatos sobre cada palabra | 29 705 |
| `tb_decoder` | `decoder` | ~3300 vectores de `gen_vectors.py` (§3.1), cada salida de control comparada | 3 299 |
| `tb_load_align` | `load_align` | casos dirigidos de `loadstore.s` y, exhaustivo en funct3 × `addr[1:0]`, 500 palabras aleatorias contra un modelo | 10 013 |
| `tb_store_align` | `store_align` | casos dirigidos y, exhaustivo en funct3 × `addr[1:0]`, 500 datos aleatorios (byte enables y replicación por carril) | 8 011 |
| `tb_imem` | `imem` | contenido inicial 0, escritura y lectura de todas las direcciones, lectura síncrona (el dato no cambia hasta el flanco), `we = 0`, 1000 ciclos aleatorios, instancia con `INIT_FILE` | 1 041 |
| `tb_dmem` | `dmem` | contenido inicial 0, puertos A y B, cada byte enable, read-first, `a_en = 0` (no escribe y mantiene `a_rdata`), el puerto B no altera `a_rdata`, 3000 ciclos aleatorios contra un modelo | 6 140 |

Las memorias se prueban con `ADDR_W = 4` (16 palabras), así se recorren todas
las direcciones. No se prueban colisiones entre puertos sobre la misma palabra
en el mismo ciclo: en una BRAM real el resultado no está definido y el diseño
nunca las produce (arquitectura.md §4.3, §6.3).

### 3.1 Vectores del decoder (`isa_vectors.hex`)

Una línea de 128 bits por vector: palabra de instrucción, `stop_code`,
salidas de control esperadas e inmediato esperado. El formato está en la
cabecera de `gen_vectors.py` y de `tb_decoder.v`.

Las salidas esperadas siguen la tabla de arquitectura.md §2.4. La legalidad y
los registros efectivos los decide `isa.decode()`, ya verificado contra las
codificaciones de RV32I en la fase 1. El inmediato se calcula aparte, con el
formato de bits de la especificación. Los vectores incluyen:
- cada instrucción con campos aleatorios, más casos con rd = x0;
- cada opcode con el resto de los bits aleatorios (la mayoría ilegales);
- palabras totalmente aleatorias;
- `NOP`, `ebreak`, `ecall`, `0x00000000`, `0xFFFFFFFF`;
- 100 vectores con `stop_code` OOR/TIMEOUT, que deben anular todo.

La semilla es fija, así que los vectores son siempre los mismos.

### 3.2 Errores inyectados (fase 2)

Se inyectó un error a la vez en el RTL y se corrió el testbench del módulo.
Los 10 errores hicieron fallar la simulación:

| Módulo | Error inyectado |
|---|---|
| `alu` | `sra` hecho como shift lógico |
| `regfile` | sin bypass en el puerto 1 |
| `imm_gen` | bit 11 del inmediato B tomado de `instr[31]` |
| `decoder` | branches con cualquier funct3 ≠ 010 aceptados como legales |
| `decoder` | `reg_write` activo con rd = x0 |
| `load_align` | `lh` sin extensión de signo |
| `store_align` | `sh` elige la mitad por `addr[0]` |
| `imem` | lectura con la dirección de escritura |
| `dmem` | `a_rdata` actualizado aunque `a_en = 0` |
| `dmem` | byte enable 2 escribe con `a_we[1]` |

## 4. Fase 3: pipeline, riesgos y HALT

**Nota de alcance:** HALT, drenaje y los motivos de detención (ILLEGAL, OOR,
TIMEOUT) se implementaron en esta fase y no en la 4. Los tests a nivel CPU
necesitan un fin de ejecución definido para comparar contra el ISS, y la
cuenta de ciclos esperada ya incluye el drenaje. La entrada `en` (enable
global) está cableada; probar el modo step queda para la fase 4.

### 4.1 Testbenches por módulo

Cada uno combina casos dirigidos con 20 000 estímulos aleatorios contra un
modelo escrito a partir de la documentación (arquitectura.md §3, §5).

| Testbench | Módulo | Qué verifica | Checks |
|---|---|---|---|
| `tb_forward_unit` | `forward_unit` | EX/MEM antes que MEM/WB, x0 nunca, un load en EX/MEM no se forwardea, `reg_write = 0` | 20 007 |
| `tb_hazard_unit` | `hazard_unit` | stall por rs1 o rs2, no con rd = x0, no con burbuja en IF/ID, no si no es load | 20 006 |
| `tb_branch_unit` | `branch_unit` | beq/bne tomado y no tomado, jalr con bit 0 en 0, burbuja sin redirect | 20 007 |
| `tb_fetch_unit` | `fetch_unit` | cada nivel de prioridad del next-PC, `imem_addr = next_pc`, `en = 0`, OOR justo en el límite, TIMEOUT antes que OOR | 20 013 |
| `tb_halt_ctrl` | `halt_ctrl` | conteo de ciclos, `en = 0`, motivo retenido, `halting` se apaga al levantar `halted`, umbral de TIMEOUT | 20 026 |
| `tb_if_id_reg` | `if_id_reg` | reset y flush a burbuja (NOP, `valid = 0`), flush gana a hold, `en = 0` | 20 006 |
| `tb_id_ex_reg` | `id_ex_reg` | reset y flush a 0, carga, `en = 0` | 20 004 |
| `tb_ex_mem_reg` | `ex_mem_reg` | reset a 0, carga, `en = 0` | 20 004 |
| `tb_mem_wb_reg` | `mem_wb_reg` | reset a 0, carga, `en = 0` | 20 004 |

### 4.2 `tb_cpu_core`: programas completos contra el ISS

`cpu_core` + `imem` + `dmem`, cargados como lo hará la Debug Unit. Para cada
programa:
1. con el core en reset, escribe el programa en imem por el puerto de
   escritura y borra la dmem por el puerto A;
2. corre con `en = 1` hasta `halted`;
3. compara con el ISS: motivo de detención, `cycle_cnt`, PC final, pipeline
   vacío, x0..x31 (puerto de debug), **las 1024 palabras de dmem** (puerto B)
   y el high-water mark.

Además, en **cada ciclo** verifica que:
- toda burbuja (`valid = 0`) tenga todos los bits de control en 0;
- nunca haya un load en MEM cuyo rd lea la instrucción en EX (el stall de
  load-use lo tiene que impedir);
- `halting` y `halted` nunca valgan 1 a la vez.

El programa anterior queda en imem más allá del nuevo, así que OOR tiene que
frenar la ejecución antes de llegar a él.

Programas (`cpu_tests.hex`, generado por `gen_vectors.py`; 104 en total):

| Grupo | Cantidad | Contenido |
|---|---|---|
| `asm/*.s` | 8 | los programas de ejemplo de la fase 1 |
| casos borde | 16 | los de `test_iss.py` y otros: ilegal en el camino equivocado, salto fuera del programa, load seguido de jalr, load seguido de store, jal consecutivos, branch a branch, fetch desalineado, aliasing de dmem |
| aleatorios | 80 | 40 a 120 instrucciones de todo el subconjunto, con registros concentrados en x0..x7 para que haya muchas dependencias, y loads/stores a cualquier dirección |

Los 104 programas terminan de todas las formas posibles:
- HALT 46, ILLEGAL 6 y OOR 11;
- TIMEOUT 41: casi todos aleatorios, bucles que corren 3000 ciclos
  atravesando todos los riesgos.

En total se ejecutan unas 83 000 instrucciones, y todas las cuentas de ciclos
coinciden exactamente con el modelo del ISS. `MAX_CYCLES = 3000` en este
testbench, y `gen_vectors.py` usa el mismo valor (el testbench lo verifica).

Resultado: **104 programas, 110 760 checks, todos correctos.**

### 4.3 Cada mecanismo es necesario: quitarlo rompe los tests

SPEC sugiere construir la fase 3 por pasos: sin riesgos, después forwarding,
después load-use, después flush. Como evidencia equivalente, se quitó **un
mecanismo a la vez** del core terminado y se corrió `tb_cpu_core`. Los 11
cambios hicieron fallar la simulación. La columna "primera falla" es el
primer programa que falló en el orden de ejecución (alfabético: `alu`,
`branches`, ...), no necesariamente el programa pensado para ese caso:

| Mecanismo quitado | Checks fallidos | Primera falla |
|---|---|---|
| forwarding EX/MEM (rs1) | 83 | `alu`: registro incorrecto |
| forwarding MEM/WB (rs2) | 24 | `alu`: registro incorrecto |
| stall de load-use | 2139 | `branches`: load en MEM alimenta a EX |
| flush de ID/EX en salto tomado | 156 | `branches`: se ejecuta el `ebreak` del camino equivocado |
| flush de IF/ID en jal | 49 | `jumps`: registro incorrecto |
| bypass WB→ID del banco (rs2) | 43 | `alu`: registro viejo |
| no aceptar HALT en el camino equivocado | 27 | `branches`: se detiene antes |
| `halted` un ciclo antes (marcador en EX/MEM) | 208 | `alu`: 28 ciclos en vez de 29 |
| límite de OOR corrido en uno | 7 | `no_halt`: cuenta de ciclos |
| jalr sin limpiar el bit 0 | 5 | `jumps`: PC final |
| flush de ID/EX sin `!if_id_valid` | 312 | burbuja con bits de control |

### 4.4 Errores inyectados en los módulos chicos

| Módulo | Error inyectado | Lo detecta |
|---|---|---|
| `forward_unit` | forwardea un load desde EX/MEM | `tb_forward_unit` |
| `hazard_unit` | stall con burbuja en IF/ID | `tb_hazard_unit` |
| `branch_unit` | bne se comporta como beq | `tb_branch_unit` |
| `fetch_unit` | `halt_accept` con prioridad sobre `ex_redirect` | `tb_fetch_unit` |
| `halt_ctrl` | `halting` no se apaga al levantar `halted` | `tb_halt_ctrl` |
| `if_id_reg` | hold le gana a flush | `tb_if_id_reg` |
| `id_ex_reg` | flush ignorado | `tb_id_ex_reg` |
| `ex_mem_reg` | `en` ignorado | `tb_ex_mem_reg` |
| `mem_wb_reg` | el reset no limpia el control | `tb_mem_wb_reg` |

## 5. Pendiente

- Fase 4: modo step (`en` pulsado ciclo a ciclo) con el mismo resultado y la
  misma cuenta de ciclos que la ejecución continua, y recarga de programas.
- Fase 5: Debug Unit y protocolo, con un testbench a nivel de bits serie.
- Fase 7: confirmar en el reporte de utilización que `imem` y `dmem` se
  infieren como `RAMB36E1`, y `regfile` como flip-flops.
