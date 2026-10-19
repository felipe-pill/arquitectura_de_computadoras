# TP3 - Herramientas del host: ensamblador, ISS y programas de ejemplo

Estado: **Fase 1 terminada**. Python 3, solo biblioteca estándar.

| Ruta | Contenido |
|---|---|
| `TP3/py/isa.py` | tabla de instrucciones del subconjunto, decodificador estricto, codificador y desensamblador |
| `TP3/py/assembler.py` | ensamblador de dos pasadas (salida .hex, .bin, .coe) |
| `TP3/py/iss.py` | simulador de referencia (ISS) con modelo de ciclos del pipeline |
| `TP3/py/gen_vectors.py` | genera los vectores de prueba de los testbenches Verilog (verificacion.md §2, §3.1) |
| `TP3/py/test_assembler.py` | tests de codificación, sintaxis, errores, decodificador y formatos de salida |
| `TP3/py/test_iss.py` | tests de semántica, HALT/OOR/TIMEOUT/ILLEGAL, ciclos y memoria |
| `TP3/asm/*.s` | programas de ejemplo, uno por característica (sección 4) |

Correr los tests desde la raíz del repo:

```
python -m unittest discover -s TP3/py -v
```

---

## 1. `isa.py`

Módulo compartido entre el ensamblador, el ISS y (en la fase 6) la CLI.

- **`decode(word)`** devuelve una `Instr(name, rd, rs1, rs2, imm)`, o `None`
  si la palabra es ilegal según arquitectura.md §2.2. Los campos de registro
  que la instrucción no usa valen 0 (rs1/rs2/rd "efectivos"), igual que en el
  decoder del hardware. Por eso es la referencia contra la que se prueba el
  decoder en Verilog (fase 2).
- **`encode(instr)`** hace lo inverso y valida rangos (inmediatos, offsets
  pares, shamt 0..31).
- **`disassemble(word)`** devuelve texto que el ensamblador vuelve a aceptar,
  por ejemplo `lw x1, -4(x2)` o `beq x1, x2, -8`. Lo va a usar la TUI.
- Constantes: `NOP`, `EBREAK` y los códigos `HALT_*` (0 NONE, 1 HALT,
  2 ILLEGAL, 3 OOR, 4 TIMEOUT), los mismos de protocol.md §6.1.

## 2. Ensamblador (`assembler.py`)

```
python TP3/py/assembler.py prog.s                  # imprime el .hex por stdout
python TP3/py/assembler.py prog.s -o out/prog      # escribe out/prog.hex, .bin y .coe
python TP3/py/assembler.py prog.s -o prog -f hex   # solo algunos formatos
```

### 2.1 Sintaxis

```
etiqueta:                     # una etiqueta puede compartir línea con una instrucción
        addi  x1, x0, 5       # comentarios con '#' o ';'
        lw    a0, -4(sp)      # registros x0..x31 o nombres ABI (zero, ra, sp, ..., fp)
        beq   x1, x2, loop    # destino: etiqueta, o un número = offset en bytes
        .word 0x00000013      # palabra literal de 32 bits
```

- Mayúsculas y minúsculas dan lo mismo.
- Inmediatos en decimal, `0x...` o `0b...`, con signo opcional.
- En branches y jal, un número se toma como **offset relativo** a la propia
  instrucción, no como dirección absoluta.
- Formas cortas: `jal destino` (= `jal ra, destino`), `jalr rs`
  (= `jalr ra, 0(rs)`), `jalr rd, rs1, imm`, `lw rd, (rs1)`.
- `lui` acepta 0..0xFFFFF, o un negativo de 20 bits (`lui x1, -1` =
  `lui x1, 0xfffff`).

### 2.2 Pseudo-instrucciones (una palabra cada una)

| Pseudo | Equivale a |
|---|---|
| `nop` | `addi x0, x0, 0` |
| `halt` | `ebreak` |
| `mv rd, rs` | `addi rd, rs, 0` |
| `li rd, imm` | `addi rd, x0, imm` (solo -2048..2047; para más, `lui` + `addi`) |
| `j destino` | `jal x0, destino` |
| `ret` | `jalr x0, 0(ra)` |

`.word` existe para poder meter a propósito una instrucción ilegal en un
programa de prueba. Ninguna de estas facilidades es obligatoria según SPEC;
son de una palabra y no complican el ensamblador.

### 2.3 Errores

Cada error indica el número de línea (`line 7: immediate 2048 out of range
[-2048, 2047]`). Se detectan:
- instrucción o registro desconocido;
- cantidad de operandos incorrecta;
- inmediatos, offsets o shamt fuera de rango;
- offsets impares;
- etiqueta inexistente, duplicada o con nombre de registro.

### 2.4 Formatos de salida

| Formato | Contenido | Uso |
|---|---|---|
| `.hex` | una palabra de 8 dígitos hex por línea, fin de línea LF | `$readmemh` en los testbenches |
| `.bin` | bytes crudos, palabras en little-endian | imagen de memoria; es exactamente el payload del comando LOAD |
| `.coe` | `memory_initialization_radix=16` + vector | formato estándar de Xilinx (SPEC §5.1) |

## 3. ISS (`iss.py`)

```
python TP3/py/iss.py TP3/asm/loop.s                    # acepta .s/.asm, .hex o .bin
python TP3/py/iss.py TP3/asm/loop.s --max-cycles 50
```

Imprime el motivo de detención, el PC final, los ciclos, las instrucciones
ejecutadas, los 32 registros y las palabras no nulas de dmem. Desde Python:
`iss.run(words, max_cycles=...)` devuelve un `Result` con `regs`, `pc`,
`dmem`, `dmem_used`, `cycles`, `instret` y `halt_reason`.

### 3.1 Qué modela

Lo mismo que reporta el hardware al terminar, para poder comparar
automáticamente (fase 3) y verificar los volcados de la Debug Unit (fase 5):

- registros, dmem y `dmem_used` (high-water mark, arquitectura.md §4.4);
- motivo de detención con la misma prioridad que el hardware: TIMEOUT > OOR >
  la instrucción misma (`ebreak` → HALT, ilegal → ILLEGAL);
- **PC final = dirección de la instrucción que detuvo la ejecución**
  (arquitectura.md §5.2);
- las mismas reglas de hardware:
  - imem y dmem en 0 con aliasing (arquitectura.md §1.4);
  - accesos desalineados (§2.3);
  - registros y dmem en 0 al empezar.

`instret` (instrucciones ejecutadas, sin contar la que detuvo) existe solo en
el ISS, para los tests: el hardware no lo reporta.

### 3.2 Modelo de ciclos

El ISS ejecuta instrucción por instrucción, pero calcula **en qué ciclo** está
cada instrucción en ID. Así obtiene la cuenta exacta de ciclos que mostrará
`cycle_cnt` y reproduce exactamente el TIMEOUT. Sea `d(k)` el ciclo en que la
instrucción dinámica `k` está en ID (el ciclo 1 es el primero habilitado tras
el reset, así que `d(0) = 2`):

```
d(k+1) = d(k) + 1 + stall(k) + penalidad(k)
```

- `stall(k) = 1` si `k-1` es un load con `rd != 0` y `k` lo lee como rs1/rs2
  efectivo;
- `penalidad(k)` = 1 para jal, 2 para jalr y para beq/bne tomados;
- el slot `k` es de TIMEOUT si `d(k) - 2 >= max_cycles` (el fetch se hizo con
  `cycle_cnt >= MAX_CYCLES`);
- el slot que detiene la ejecución llega a WB y levanta `halted` en el ciclo
  `d + 3`, que es la cuenta final.

Esto equivale a la fórmula de arquitectura.md §3.3:
`ciclos = N + 4 + stalls + 2·(saltos tomados + jalr) + jal`.

## 4. Programas de ejemplo (`TP3/asm/`)

Cada programa tiene comentarios con los valores esperados, deducidos a mano a
partir de la especificación, y `test_iss.py` los verifica.

| Programa | Qué prueba | Fin | Ciclos |
|---|---|---|---|
| `alu.s` | todas las operaciones R e I de la ALU, `lui`, escritura en x0 | HALT | 29 |
| `loadstore.s` | lb/lh/lw/lbu/lhu y sb/sh/sw en todos los carriles, extensión de signo, offset negativo | HALT | 26 |
| `forwarding.s` | forwarding EX/MEM y MEM/WB, prioridad del más nuevo, dato y dirección de store, bypass WB→ID, x0 no se forwardea | HALT | 21 |
| `load_use.s` | 3 stalls de load-use (rs1/rs2, dato de store) y casos sin stall (distancia 2, rd = x0, `ebreak`) | HALT | 22 |
| `branches.s` | beq/bne tomados y no tomados, hacia adelante y atrás, load → branch, `ebreak` e ilegal en el camino equivocado | HALT | 41 |
| `jumps.s` | llamada y retorno con jal/jalr, jalr con rd = rs1 y destino impar | HALT | 22 |
| `loop.s` | bucle con sumas parciales guardadas en un arreglo | HALT | 78 |
| `no_halt.s` | programa sin HALT: se sale del final | OOR en PC = 0x0c | 8 |

Además, `test_iss.py` cubre con programas cortos:
- ILLEGAL;
- TIMEOUT (bucle infinito y el límite exacto);
- salto fuera del programa (OOR);
- aliasing de dmem;
- accesos y fetch desalineados.

## 5. Cómo se verificaron los tests

Además de pasar, los tests se validaron inyectando 9 errores a propósito en
`isa.py` e `iss.py`, de a uno: shift aritmético como lógico, sin stall de
load-use, penalidad de jal incorrecta, límite de TIMEOUT corrido en uno,
bits de inmediato de branch y de jal mal ubicados, codificación de `sra`
incorrecta, jalr sin limpiar el bit 0, y cuenta final de ciclos corrida en
uno. Cada error hizo fallar al menos un test.
