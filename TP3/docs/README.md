# TP3 - Procesador RV32I segmentado con Debug Unit

Procesador RISC-V RV32I de 5 etapas (IF, ID, EX, MEM, WB) con una Debug Unit
por UART, para la Basys 3. La especificación completa está en
[`../SPEC.md`](../SPEC.md).

## Estado

| Fase | Contenido | Estado |
|---|---|---|
| 0 | Diseño: arquitectura, módulos, protocolo UART | hecha |
| 1 | Ensamblador e ISS en Python, con tests | hecha |
| 2 | Módulos del datapath (ALU, banco de registros, decoder, memorias, ...) | hecha |
| 3 | Pipeline completo: forwarding, load-use, saltos, **HALT y drenaje** | hecha |
| 4 | Modo step, enable global y reset (verificación, sin cambios de RTL) | hecha |
| 5 | Debug Unit y protocolo UART, con testbench a nivel de bits serie | hecha |
| 6 | CLI en Python para la placa | hecha |
| 7 | Tope de placa, constraints, build, timing, frecuencia del MMCM | pendiente |
| 8 | Documentación final y respuestas a las preguntas de SPEC §8 | pendiente |

Cambio respecto del orden de SPEC: HALT y drenaje se hicieron en la fase 3 y
no en la 4, porque los tests a nivel CPU necesitan un fin de ejecución
definido para comparar contra el ISS (verificacion.md §4).

## Dónde está cada cosa

| Carpeta | Contenido |
|---|---|
| `TP3/src/` | RTL sintetizable (Verilog-2001), un módulo por archivo |
| `TP3/sim/` | testbenches autoverificables (`tb_*.v`), `prebuild.bat` y datos fijos (`data/`) |
| `TP3/py/` | ensamblador, ISS, generador de vectores de prueba, protocolo y CLI para la placa, y sus tests |
| `TP3/asm/` | programas de ejemplo, uno por característica |
| `TP3/docs/` | esta documentación |

## Cómo se corre

Desde la raíz del repo:

```
.\sim.bat TP3 tb_cpu_core                        # un testbench (lista en verificacion.md)
python -m unittest discover -s TP3/py -v         # tests de Python
python TP3/py/assembler.py TP3/asm/loop.s        # ensamblar
python TP3/py/iss.py TP3/asm/loop.s              # simular en el ISS
python TP3/py/cli.py --port COM5                 # CLI con la placa conectada
```

Detalles en verificacion.md §1 y herramientas.md.

## Documentos

| Documento | Contenido |
|---|---|
| [arquitectura.md](arquitectura.md) | diagramas de bloques (Mermaid), decodificación, riesgos, memorias/BRAM, HALT y drenaje, enable global y step, resets, lectura de estado, reuso de TPs anteriores |
| [modulos.md](modulos.md) | jerarquía y puertos de cada módulo |
| [protocol.md](protocol.md) | protocolo UART: tramas, comandos, errores, formato exacto del volcado, ejemplos |
| [verificacion.md](verificacion.md) | cómo se simula, solución de `$readmemh` (pre-build), qué cubre cada testbench, errores inyectados para validar los tests |
| [herramientas.md](herramientas.md) | ensamblador, ISS (con modelo de ciclos), generador de vectores, programas de `asm/`, CLI para la placa |

## Resumen de decisiones

| Tema | Decisión | Detalle |
|---|---|---|
| Mapa de memoria | Harvard, imem y dmem en 0, aliasing por encima del tamaño | arq. §1.4 |
| Tamaños | imem 1K×32, dmem 1K×32 (1 RAMB36 cada una), parametrizables | arq. §1.3 |
| HALT | `ebreak` (`0x00100073`) | arq. §2.1 |
| Instrucciones ilegales | se tratan como HALT con motivo ILLEGAL | arq. §2.2 |
| WB→ID | bypass interno en el banco de registros (no flanco descendente) | arq. §3.1 |
| Forwarding | EX/MEM y MEM/WB hacia EX, siempre desde flip-flops | arq. §3.1 |
| Load-use | 1 ciclo de stall; rs efectivos para evitar dependencias falsas | arq. §3.2 |
| Saltos | beq/bne/jalr en EX (2 ciclos), jal en ID (1 ciclo), predicción "no tomado" | arq. §3.3 |
| Memorias | BRAM inferida (no IP), direccionada un ciclo antes: imem con `next_pc`, dmem con la dirección de EX | arq. §4.1-4.2 |
| Stores | se escriben al final de EX (consecuencia de lo anterior; seguro porque EX nunca se cancela) | arq. §4.2 |
| Debug sobre dmem | puerto B de solo lectura: el volcado no pisa el pipeline | arq. §4.3 |
| Memoria "usada" | high-water mark por palabra | arq. §4.4 |
| HALT y drenaje | marcador HALT que viaja hasta WB; `halted` cuando sale, con los 4 registros vacíos; PC final = dirección de la instrucción que detuvo (convención de `mepc` y GDB) | arq. §5 |
| Sin HALT | OOR (`PC >= 4*prog_len`) + TIMEOUT (`MAX_CYCLES` fijo = 1 000 000, 10 ms a 100 MHz) | arq. §5.4 |
| Step | `core_en = running \|\| step_pulse` en los CE de FFs y BRAM; el reloj no se toca | arq. §6 |
| Reset | RESET y LOAD borran registros y dmem; la imem no se borra; registros en 0, incluido `sp` | arq. §6.3 |
| UART | TP2 sin cambios, 115200 8N1; tramas `SOF CMD LEN PAYLOAD CHK`; solo LOAD, RESET, RUN, STEP y DUMP | protocol.md |

Quedan fuera de alcance, a propósito, para no sobrediseñar: PING, BREAK,
RESET durante RUN, READ_MEM, límite de ciclos configurable desde el host,
contador de instrucciones retiradas y byte de riesgos en el volcado (el host
deduce forwarding, stall y flush de los registros de pipeline).
