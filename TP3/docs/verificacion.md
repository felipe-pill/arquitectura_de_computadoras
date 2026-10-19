# TP3 - Verificación (simulación)

Estado: **Fase 2 terminada** (módulos del datapath con sus testbenches).

## 1. Cómo se corre

Desde la raíz del repo:

```
.\sim.bat TP3 <testbench>          # por ejemplo: .\sim.bat TP3 tb_decoder
.\sim.bat TP3 <testbench> gui      # con formas de onda
python -m unittest discover -s TP3/py -v    # tests de Python (fase 1)
```

Cada testbench es autoverificable, según CLAUDE.md:
- imprime `PASS`/`FAIL` con entradas, valor esperado y valor obtenido;
- ante cualquier diferencia imprime una línea con `TEST FAILED`;
- al final imprime `ALL TESTS PASSED (N checks)` o llama a `$fatal`.

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
2. corre `python TP3/py/gen_vectors.py <build>`, que genera los vectores de
   prueba (por ahora `isa_vectors.hex`).

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

## 3. Testbenches de la fase 2

| Testbench | Módulo | Qué verifica | Checks |
|---|---|---|---|
| `tb_alu` | `alu` | 25 casos dirigidos (overflow, signo, shift por `b[4:0]`, `srai` con imm 0x401, ops inválidas = 0) y 2000 aleatorios por operación contra un modelo de la especificación | 20 025 |
| `tb_regfile` | `regfile` | reset, escritura y lectura de los 32 registros, x0 ignora escrituras, bypass en el mismo ciclo en los dos puertos (no en el de debug), `we = 0`, reset con prioridad sobre la escritura, 3000 ciclos aleatorios contra un modelo | 9 275 |
| `tb_imm_gen` | `imm_gen` | 11 inmediatos conocidos (I/S/B/U/J con extremos), `imm_sel` 5..7 = 0, los ~3300 vectores de Python y además todos los formatos sobre cada palabra | 29 705 |
| `tb_decoder` | `decoder` | ~3300 vectores de `gen_vectors.py` (ver 3.1), cada salida de control comparada | 3 299 |
| `tb_load_align` | `load_align` | casos dirigidos de `loadstore.s` y, exhaustivo en funct3 × `addr[1:0]`, 500 palabras aleatorias contra un modelo | 10 013 |
| `tb_store_align` | `store_align` | casos dirigidos y, exhaustivo en funct3 × `addr[1:0]`, 500 datos aleatorios (byte enables y replicación por carril) | 8 011 |
| `tb_imem` | `imem` | contenido inicial 0, escritura y lectura de todas las direcciones, lectura síncrona (el dato no cambia hasta el flanco), `we = 0`, 1000 ciclos aleatorios, instancia con `INIT_FILE` | 1 041 |
| `tb_dmem` | `dmem` | contenido inicial 0, puertos A y B, cada byte enable, read-first, `a_en = 0` (no escribe y mantiene `a_rdata`), el puerto B no altera `a_rdata`, 3000 ciclos aleatorios contra un modelo | 6 140 |

Las memorias se prueban con `ADDR_W = 4` (16 palabras), así se recorren todas
las direcciones. No se prueban colisiones entre puertos sobre la misma palabra
en el mismo ciclo: en una BRAM real el resultado no está definido y el diseño
nunca las produce (arquitectura.md §4.3, §6.3).

### 3.1 Vectores del decoder (`gen_vectors.py`)

`isa_vectors.hex` tiene una línea de 128 bits por vector: palabra de
instrucción, `stop_code`, salidas de control esperadas e inmediato esperado.
El formato está en la cabecera de `gen_vectors.py` y de `tb_decoder.v`.

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

## 4. ¿Los tests detectan errores?

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

## 5. Pendiente para las fases siguientes

- Fase 3: `forward_unit`, `hazard_unit`, `branch_unit`, registros de pipeline
  y `cpu_core`, con tests a nivel CPU. `gen_vectors.py` va a ensamblar los
  programas de `asm/` y escribir el resultado esperado del ISS (registros,
  dmem, PC, ciclos, motivo) para que el testbench compare.
- Fase 7: confirmar en el reporte de utilización que `imem` y `dmem` se
  infieren como `RAMB36E1`, y `regfile` como flip-flops.
