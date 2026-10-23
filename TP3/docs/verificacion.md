# TP3 - Verificación (simulación)

Estado: **Fase 5 terminada**. El core, la Debug Unit y `system_top` están
verificados, incluido el protocolo UART a nivel de bits serie. Los 24
testbenches dan `SIM OK`.

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

## 5. Fase 4: modo step, enable global y reset

SPEC asigna a esta fase HALT y drenaje, enable global y step, e imem
escribible. HALT y drenaje se hicieron en la fase 3 (§4). La imem escribible
ya está probada en `tb_imem` (puerto de escritura) y en `tb_cpu_core`, que
carga un programa nuevo en cada test sin borrar el anterior. Lo que faltaba
era verificar el enable: **en esta fase no cambió el RTL**, solo se agregó
`tb_cpu_step`.

### 5.1 `tb_cpu_step`

Usa los mismos 104 programas de `cpu_tests.hex` y corre cada uno tres veces:

1. **Continua (`en = 1`), grabando una traza:** el vector de debug completo
   (PC y los cuatro registros de pipeline) después de cada flanco, y la
   escritura en dmem de cada flanco.
2. **Con `en` aleatorio** (proporción de ciclos habilitados 1/2, 1/4 o 3/4,
   o alternado, según el programa):
   - en cada flanco habilitado, la escritura en dmem y el estado resultante
     tienen que ser **idénticos a la traza continua en la misma cuenta de
     ciclos**;
   - en cada flanco deshabilitado no puede cambiar nada: ni el estado, ni
     `cycle_cnt`, ni la dirección de imem (queda en el PC), y no puede haber
     enable ni escritura en dmem ni escritura en el banco de registros (se
     verifica el registro destino de MEM/WB y uno rotativo);
   - una vez `halted`, 8 ciclos más con `en = 1` no cambian nada;
   - el estado final coincide con el ISS: registros, las 1024 palabras de
     dmem, PC, ciclos y motivo.
3. **Reset a mitad de ejecución:** corre continuo un número aleatorio de
   ciclos, aplica un reset como el comando RESET (programa conservado, dmem
   borrada) y vuelve a correr completo. El estado final coincide con el ISS,
   así que el reset deja el core limpio desde cualquier estado del pipeline.

Resultado: **104 programas, 823 618 checks, todos correctos.** El modo step
es equivalente a la ejecución continua ciclo a ciclo, no solo en el
resultado final.

### 5.2 Errores inyectados

| Error inyectado | Primera falla detectada |
|---|---|
| escritura del banco de registros sin `en` | registro escrito con `en = 0` |
| enable de lectura de dmem sin `en` | dmem habilitada con `en = 0` |
| escritura en dmem sin `en` | dmem habilitada con `en = 0` |
| next-PC (dirección de imem) sin `en` | dirección de imem movida con `en = 0` |
| `halt_ctrl` sin `en` | `cycle_cnt` cambió con `en = 0` |
| `halted` no bloquea `en` | el estado cambió después de `halted` |
| IF/ID sin `en` | el estado cambió con `en = 0` |
| el reset no limpia el banco de registros | el estado difiere de la ejecución continua |

El primero sobrevivió a la primera versión del testbench. Mientras el core
está congelado, MEM/WB tiene la misma instrucción, así que el error escribe
**el mismo valor en el mismo registro** en cada flanco: el estado final es
idéntico y la traza de los registros de pipeline también. Pero en modo step
se nota: un volcado mostraría el registro ya escrito con su instrucción
todavía en WB, un paso antes. Por eso se agregó el chequeo del banco de
registros durante los ciclos congelados, y con él el error se detecta.

## 6. Fase 5: Debug Unit y protocolo UART

La UART de TP2 (`uart`, `uart_baudgen`, `uart_rx`, `uart_tx`) se copió sin
cambios, junto con su testbench `tb_uart_loopback`, que pasa en TP3.

### 6.1 Testbenches de los submódulos (nivel de byte, sin UART)

| Testbench | Módulo | Qué verifica | Checks |
|---|---|---|---|
| `tb_dbg_rx_frame` | `dbg_rx_frame` | ejemplos de protocol.md §7, checksum malo, basura antes del SOF, `A5` dentro del payload, timeout entre bytes (y una pausa justo por debajo del límite), error de framing en una trama y en reposo, 300 tramas aleatorias (comando, largo 0-39, payload, pausas y corrupción aleatorios) | 310 |
| `tb_dbg_tx_frame` | `dbg_tx_frame` | tramas con payload de 0, 1, 2, 17, 204 y 300 bytes contra un modelo del handshake de `uart_tx` (busy aleatorio) y una fuente de bytes con latencia aleatoria: bytes, orden de pedidos, checksum, `done` una sola vez, nunca `tx_start` con `tx_busy` | 6 |
| `tb_dbg_state_src` | `dbg_state_src` | cada byte de un STATE completo y 500 índices al azar contra un modelo del layout de protocol.md §6, latencia exacta de 3 ciclos, modo corto | 770 |

### 6.2 `tb_system_top`: protocolo con bits serie reales

El testbench maneja `uart_rxd` bit a bit (8N1) y decodifica `uart_txd`.
Para que la simulación sea rápida, la UART corre a `CLK_FREQ/32` baudios
(`DIV = 2`, 32 ciclos por bit). La lógica de bits es la misma que a 115200,
que ya cubren TP2 y `tb_uart_loopback`.

Los STATE esperados salen de un **core de referencia**: otro `cpu_core` con
sus memorias, manejado directamente (un pulso de `en` por STEP, `en` hasta
`halted` en RUN, reset y borrado en RESET y LOAD). Cada respuesta STATE tiene
que ser **idéntica byte a byte** al volcado armado desde ese core, y el
resultado final de cada RUN se compara además con el ISS.

Qué cubre:
- **Encendido:** DUMP con todo en cero y sin programa.
- **Errores y orden de chequeo:**
  - STEP/RUN sin programa → `ERR_NO_PROGRAM`;
  - comando desconocido → `ERR_UNKNOWN_CMD`;
  - checksum malo → `ERR_CHECKSUM`, también con un LEN inválido o un comando
    desconocido, porque el checksum se chequea primero;
  - LEN inválido en DUMP, RUN y LOAD (6 y 0 bytes) → `ERR_LENGTH`;
  - RUN/STEP con el core detenido → `ERR_HALTED`.
- **Programas:**
  - `load_use` y `jumps` **paso a paso hasta el final** (22 STEP cada uno,
    cada STATE comparado);
  - `alu`, `no_halt`, `random_05` con algunos STEP y después RUN;
  - `branches`, `illegal`, `random_17` con RUN directo.
- **RESET a mitad de programa** (`loadstore`): 7 STEP, RESET, DUMP, 2 STEP,
  RUN, y otro RESET + RUN completo. Los STEP de `loadstore` incluyen stores,
  así que el largo de la respuesta (`dmem_used`) cambia entre pasos.
- **Trama durante RUN:** con `timeout_loop` se envía un DUMP mientras corre.
  La respuesta del RUN llega (TIMEOUT, 3005 ciclos, igual que el ISS) y el
  DUMP no recibe respuesta.
- **LOAD con checksum malo:** `ERR_CHECKSUM`; después RUN da
  `ERR_NO_PROGRAM` y DUMP muestra `prog_valid = 0`.
- **Timeout entre bytes y error de framing:** la trama incompleta no recibe
  respuesta y la siguiente funciona.
- **Al final:** no quedan bytes inesperados y no hubo errores de framing en
  `uart_txd`.

Resultado: **150 checks, todos correctos**: 94 respuestas STATE comparadas
byte a byte con el core de referencia y 11 resultados finales comparados con
el ISS.

`dbg_ctrl` y `debug_unit` no tienen testbench propio: su comportamiento es
el protocolo, y `tb_system_top` lo verifica de punta a punta.

### 6.3 Errores inyectados

Contra `tb_system_top`, uno a la vez, todos detectados:

| Error inyectado | Primera falla detectada |
|---|---|
| largo de la respuesta de STEP calculado antes del store de ese paso | `load_use/step`: largo 204 en vez de 208 |
| checksum no chequeado primero | `dump_bad_chk`: respondió STATE en vez de `ERR_CHECKSUM` |
| sin `ERR_HALTED` | `load_use/run_halted` |
| un LOAD con checksum malo deja un programa válido | `after_bad_load/run` |
| palabras de LOAD armadas big-endian | `load_use/step`: instrucción en IF/ID |
| RESET no limpia `dmem_used` | `jumps/dump`: largo 212 en vez de 204 |
| sin timeout entre bytes | `rx_timeout/dump`: sin respuesta |
| registros enviados big-endian | `load_use/step`: byte 80 |
| checksum de respuesta incluye el SOF | `power_on/dump`: checksum malo |
| flags `halted` y `halting` invertidos | `load_use/step`: byte 0 |

El primero es un error real que tuvo la primera versión de `dbg_ctrl` (se
corrigió agregando el estado `S_STEP_LEN` antes de correr los tests); el test
lo detecta.

En los submódulos, cada testbench detectó su error:
- `dbg_rx_frame`: el checksum ignora el byte CHK;
- `dbg_tx_frame`: LEN_hi envía LEN_lo;
- `dbg_state_src`: latencia 2 en vez de 3.

## 7. Pendiente

- Fase 7: confirmar en el reporte de utilización que `imem` y `dmem` se
  infieren como `RAMB36E1`, y `regfile` como flip-flops.
- Fase 7: probar en la placa a 115200 baudios reales.
