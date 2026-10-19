# TP3 - Documentación de diseño

Procesador RISC-V RV32I segmentado en 5 etapas con Debug Unit por UART, para
Basys 3. Especificación: [`../SPEC.md`](../SPEC.md).

Estado: **Fases 0 y 1 revisadas; Fase 2 (módulos del datapath) terminada.**

| Documento | Contenido |
|---|---|
| [arquitectura.md](arquitectura.md) | diagramas de bloques (Mermaid), decodificación, riesgos, memorias/BRAM, HALT y drenaje, enable global y step, resets, lectura de estado, reuso de TPs anteriores |
| [modulos.md](modulos.md) | jerarquía y puertos de cada módulo |
| [protocol.md](protocol.md) | protocolo UART completo: tramas, comandos, errores, formato exacto del volcado, ejemplos |
| [verificacion.md](verificacion.md) | cómo se simula, solución de `$readmemh` (pre-build), qué cubre cada testbench, errores inyectados |
| [herramientas.md](herramientas.md) | ensamblador, ISS (con modelo de ciclos), programas de ejemplo de `TP3/asm/` y cómo correr los tests |

## Resumen de decisiones

| Tema | Decisión | Detalle |
|---|---|---|
| Mapa de memoria | Harvard, imem y dmem en 0, aliasing por encima del tamaño (confirmado) | arq. §1.4 |
| Tamaños | imem 1K×32, dmem 1K×32 (1 RAMB36 cada una), parametrizables | arq. §1.3 |
| HALT | `ebreak` (`0x00100073`) | arq. §2.1 |
| Instrucciones ilegales | se tratan como HALT con motivo ILLEGAL (confirmado) | arq. §2.2 |
| WB→ID | bypass interno en el banco de registros (no flanco descendente) | arq. §3.1 |
| Forwarding | EX/MEM y MEM/WB hacia EX, siempre desde flip-flops | arq. §3.1 |
| Load-use | 1 ciclo de stall; rs efectivos para evitar dependencias falsas | arq. §3.2 |
| Control | beq/bne/jalr en EX (2 ciclos), jal en ID (1 ciclo), predicción "no tomado" | arq. §3.3 |
| Memorias | BRAM inferida (no IP), direccionada un ciclo antes: imem con `next_pc`, dmem con la dirección de EX | arq. §4.1-4.2 |
| Stores | se escriben al final de EX (consecuencia de lo anterior; seguro porque EX nunca se cancela) | arq. §4.2 |
| Debug sobre dmem | puerto B de solo lectura: el volcado no pisa el pipeline | arq. §4.3 |
| Memoria "usada" | high-water mark por palabra | arq. §4.4 |
| HALT y drenaje | marcador HALT que viaja hasta WB; `halted` cuando sale, con los 4 registros vacíos | arq. §5 |
| Sin HALT | OOR (`PC >= 4*prog_len`) + TIMEOUT (`MAX_CYCLES` = 1 000 000) | arq. §5.4 |
| Step | `core_en = running \|\| step_pulse` en los CE de FFs y BRAM; el reloj no se toca | arq. §6 |
| Reset | RESET y LOAD borran registros y dmem; la imem no se borra | arq. §6.3 |
| UART | TP2 sin cambios, 115200 8N1; tramas `SOF CMD LEN PAYLOAD CHK`; solo LOAD, RESET, RUN, STEP y DUMP | protocol.md |

## Decisiones confirmadas en la revisión

1. **Saltos resueltos en EX** (jal en ID), con predicción "no tomado"
   (arq. §3.3).
2. **Stores escritos al final de EX** (arq. §4.2).
3. **PC final = dirección de la instrucción que detuvo la ejecución**
   (convención de `mepc` y de GDB) (arq. §5.2).
4. **Sin extras:** el protocolo tiene solo los cinco comandos que pide SPEC.
   Quedan fuera de alcance PING, BREAK, RESET durante RUN, READ_MEM, límite de
   ciclos configurable desde el host, contador de instrucciones retiradas y
   byte de riesgos en el volcado (el host deduce forwarding/stall/flush de los
   registros de pipeline).
5. **Límite de ciclos fijo** `MAX_CYCLES = 1 000 000` (10 ms a 100 MHz), como
   parámetro de síntesis (arq. §5.4).
6. **Registros en 0 tras reset**, incluido `sp`: los programas de `asm/`
   inicializan lo que usan (arq. §6.3).
7. El intento anterior en `TP3/src` y `TP3/sim` se borra al empezar la fase 2
   (si no, `sim.bat` lo compila junto con lo nuevo).
