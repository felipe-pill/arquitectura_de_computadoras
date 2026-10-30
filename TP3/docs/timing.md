# TP3 - Tope de placa, build y timing (fase 7)

Estado: **fase 7 terminada**. Frecuencia de operación: **94,444 MHz**, con
timing cumplido (WNS +0,216 ns, WHS +0,095 ns) y los 8 programas de `asm/`
iguales al ISS en la placa (§7).

Documentos relacionados: [arquitectura.md](arquitectura.md) (en especial
§4.2 y §4.4.1), [modulos.md](modulos.md), [verificacion.md](verificacion.md).

Todos los números salen de los reportes de Vivado 2025.1 para la
xc7a35tcpg236-1 (grado de velocidad −1), en `build/TP3/vivado/`.

---

## 1. Tope de placa (`basys3_top`)

```
clk100mhz (W5) ─► MMCME2_BASE ─► BUFG ─► clk_sys ─► system_top y sincronizador de reset
                      ▲  CLKFBOUT
                      └─ BUFG ◄──┘
```

- **MMCM:** la primitiva `MMCME2_BASE` se instancia directamente, sin
  Clocking Wizard ni `.xci` (igual que la BRAM inferida de arquitectura.md
  §4.1: no hay archivos que dependan de la versión de Vivado).
  `clk_sys = 100 MHz · MMCM_MULT / (MMCM_DIVCLK · MMCM_OUT_DIV)`, y el VCO
  (`100 MHz · MMCM_MULT / MMCM_DIVCLK`) tiene que quedar entre 600 y
  1200 MHz. Los tres valores son parámetros de `basys3_top`, que también
  calcula `CLK_FREQ_HZ` para la UART y el timeout de la Debug Unit.
- **Realimentación por un BUFG:** `CLKFBOUT` vuelve a `CLKFBIN` pasando por
  un BUFG igual al de `clk_sys`. Así el MMCM compensa el retardo del árbol de
  reloj, y el flanco de `clk_sys` en los flip-flops queda alineado con el del
  pin de entrada (§6).
- **Reset:** `btn_reset | !mmcm_locked` pasa por el sincronizador 2FF
  (`ASYNC_REG`, init `2'b11`). Mientras el MMCM no enganchó, todo el sistema
  está en reset.
- **LEDs:** `[0]` running, `[1]` halting, `[2]` halted, `[5:3]` halt_reason.
- **El reloj no se toca:** el MMCM es generación de reloj, no intervención
  (SPEC §4). No hay gating ni relojes divididos; un único dominio, `clk_sys`.

`basys3_top` no tiene testbench: las primitivas de Xilinx no se simulan sin
sus modelos (SPEC §4). Lo de abajo (`system_top`) está simulado; el tope se
prueba en la placa (§7).

### Constraints (`TP3/constrs/basys3.xdc`)

- Pines: reloj W5, reset U18 (botón central), UART B18/A18 (los de TP2) y los
  16 LEDs.
- Solo se restringe el reloj de entrada (`create_clock` de 10 ns); Vivado
  deriva solo el reloj de salida del MMCM.
- `set_false_path` en `btn_reset`, `uart_rxd`, `uart_txd` y los LEDs: las
  entradas pasan por sincronizadores 2FF, y las salidas las lee una persona o
  una UART a 115200, no un dispositivo con el mismo reloj. No tienen un
  timing de I/O con sentido.

---

## 2. Build

```
.\build.bat TP3                                    # frecuencia por defecto (94,444 MHz)
.\build.bat TP3 MMCM_MULT 49 MMCM_DIVCLK 5 MMCM_OUT_DIV 10   # otra frecuencia (98 MHz)
```

`build.bat` llama a Vivado en modo batch (no hace falta tenerlo en el PATH:
la ruta está en el script, igual que en `sim.bat`) con
`TP3/scripts/build.tcl`, un flujo **sin proyecto**:

1. `read_verilog` de `TP3/src/*.v` y `read_xdc`;
2. `synth_design`, con los pares `nombre valor` como `-generic` (sirvieron
   para el barrido de frecuencias sin tocar el RTL);
3. `opt_design`, `place_design`, `route_design`;
4. reportes: `timing_summary.rpt`, `timing_paths.rpt` (10 peores caminos con
   detalle), `utilization.rpt`, `utilization_hier.rpt`,
   `clock_utilization.rpt`, `drc.rpt`;
5. si WNS o WHS son negativos, **se detiene sin generar el bitstream**;
6. `write_bitstream` → `build/TP3/vivado/basys3_top.bit`.

El build con los valores por defecto genera el mismo bitstream que el del
barrido a 94,444 MHz: los dos `.bit` difieren solo en 3 bytes del
encabezado (la hora del build).

**Programación:** desde el Hardware Manager de Vivado (Open Target → Auto
Connect → Program Device). Se carga en la configuración de la FPGA, así que
se pierde al apagar la placa.

---

## 3. Utilización (94,444 MHz)

| Recurso | Usado | Disponible | % |
|---|---|---|---|
| LUTs | 2451 | 20 800 | 11,8 |
| Flip-flops | 1860 | 41 600 | 4,5 |
| RAMB36E1 | 2 | 50 | 4,0 |
| LUTRAM | 0 | 9600 | 0 |
| MMCM | 1 | 5 | 20 |
| BUFG | 2 | 32 | 6,3 |
| IOB | 20 | 106 | 18,9 |

Por módulo:

| Instancia | LUTs | FFs | RAMB36 |
|---|---|---|---|
| `cpu_core` | 1945 | 1437 | 0 |
| ↳ `regfile` | 840 | 992 | 0 |
| ↳ `id_ex_reg` (incluye la ALU) | 470 | 159 | 0 |
| ↳ `mem_wb_reg` (incluye parte del forwarding) | 392 | 73 | 0 |
| `debug_unit` | 366 | 364 | 0 |
| `imem` | 73 | 0 | 1 |
| `dmem` (absorbida en `system_top`) | - | - | 1 |
| `uart` | 48 | 57 | 0 |

- Las dos memorias se infieren como **RAMB36E1**, sin LUTRAM (lo que pedía
  arquitectura.md §4.1).
- El banco de registros son **992 flip-flops** (31 × 32; x0 no existe), como
  estaba previsto. Sus 840 LUTs son los multiplexores de lectura (los dos
  puertos del core y el de depuración) y el bypass WB→ID.
- La síntesis optimiza a través de los límites de los módulos, así que
  parte de la lógica combinacional del core queda asignada a submódulos
  vecinos: por eso la ALU aparece dentro de `id_ex_reg` y parte del
  forwarding dentro de `mem_wb_reg` en el reporte jerárquico.

---

## 4. Camino crítico

### 4.1 El camino final (94,444 MHz)

| | |
|---|---|
| Origen | `u_core/u_mem_wb/ctrl_reg[5]` (registro MEM/WB) |
| Destino | `u_imem/mem_reg/ADDRBWRADDR[11]` (dirección de lectura de la imem) |
| Requerimiento | 10,588 ns |
| Retardo de datos | 9,726 ns: lógica 2,543 ns (26 %), ruteo 7,183 ns (74 %) |
| Niveles de lógica | 12 (3 CARRY4, 9 LUT) |
| Skew del reloj | 0,012 ns |
| Incertidumbre | 0,093 ns |
| Slack | **+0,216 ns** |

Recorrido:

    MEM/WB → selección de forwarding → operando de la ALU → sumador de 32 bits
           → destino de jalr/branch → mux de next_pc → dirección de la imem (BRAM)

Es el camino de EX que anticipaba arquitectura.md §4.2: como las memorias son
BRAM síncronas, se direccionan **un ciclo antes**. La imem recibe `next_pc`,
que en un salto tomado sale de la ALU en EX, y la dmem recibe la dirección
del store, que también sale de la ALU en EX. Así, el forwarding, la ALU y el
setup de la BRAM entran en un mismo ciclo. El 74 % del retardo es ruteo: el
camino cruza el dispositivo, desde los registros de pipeline hasta los
bloques de BRAM.

### 4.2 Cómo fue cambiando

| Build | Fin del peor camino | Niveles | Datos | WNS |
|---|---|---|---|---|
| 100 MHz, `dmem_used` en el mismo ciclo | `dmem_used` (Debug Unit) | 14 | 10,847 ns | −1,091 ns |
| 100 MHz, `dmem_used` un ciclo después | `WEA` de la dmem (byte-enable del store) | 11 | 9,503 ns | −0,102 ns |
| 94,444 MHz (final) | dirección de lectura de la imem | 12 | 9,726 ns | +0,216 ns |

El primer camino crítico era de la Debug Unit: el high-water mark de la dmem
comparaba la dirección del store en el mismo ciclo. Se corrigió registrando
primero la escritura (arquitectura.md §4.4.1), y a partir de ahí todos los
caminos críticos son del core. Los dos últimos son variantes del mismo
recorrido (forwarding → ALU → pin de una BRAM); cuál de los dos queda
primero cambió entre builds (§5.2).

### 4.3 Mejoras posibles (no implementadas)

- Registrar `next_pc` y leer la imem con el PC (IF en 2 ciclos): saca la ALU
  del camino de la imem, a cambio de una etapa más y más penalidad por salto
  (alternativa ya descartada en arquitectura.md §4.2).
- Directivas de mayor esfuerzo de Vivado (`-directive Explore`,
  `phys_opt_design`). Mejoran la ubicación, no el diseño; el flujo se dejó
  con las opciones por defecto para que los números sean reproducibles.

---

## 5. Frecuencia de operación

### 5.1 Cómo se eligió la frecuencia

**Cómo se leen los reportes.** En cada build se miraron:
- en `timing_summary.rpt`:
  - **WNS** (*worst negative slack*): el slack de setup del peor camino.
    Positivo = cumple;
  - **TNS**: la suma de los slacks negativos;
  - la cantidad de **endpoints fallidos**;
  - **WHS**: el peor slack de hold;
- en `timing_paths.rpt`, para el peor camino:
  - origen y destino;
  - niveles de lógica;
  - cuánto del retardo es lógica y cuánto ruteo;
  - skew e incertidumbre del reloj.

La frecuencia máxima que permite un build se estima como `1 / (T − WNS)`,
con `T` el período pedido. `build.tcl` se detiene sin generar el bitstream
si WNS o WHS son negativos.

Los pasos, en el orden en que se hicieron:

**1. Primer build, a 100 MHz** (MMCM 10 / 1 / 10, el reloj de la placa
sin cambios).
- Falló: WNS = −1,091 ns, TNS = −27,414 ns, 81 endpoints fallidos (hold
  bien, WHS = +0,131 ns).
- Los 81 endpoints eran bits de `dmem_used`, el high-water mark de la
  Debug Unit. El camino salía del registro MEM/WB y pasaba por el
  forwarding y la ALU: 14 niveles de lógica, 75 % de ruteo.
- Con ese build, el máximo era ~90 MHz (`1 / 11,09 ns`).

**2. Puesta en marcha a 50 MHz** (10 / 1 / 20).
- **Decisión:** antes de buscar la frecuencia, probar la placa a una
  frecuencia que cumpla con margen. Así, si algo falla en la placa, se sabe
  si el problema es el tope (MMCM, reset, pines, programación) o el timing.
- 50 MHz conserva el mismo error de baudios que 100 MHz (§5.3).
- Resultado: WNS = +4,498 ns, WHS = +0,059 ns y el bitstream generado.
  Los 8 programas de `asm/` dieron igual al ISS en la placa (§7). En ese
  build también se confirmó que las memorias son BRAM (§3).

**3. Cambio de RTL para mejorar el WNS.**
- El reporte del paso 1 mostraba que el límite no era el procesador sino
  un contador de depuración. Había dos caminos:
  - medir el diseño como estaba (~90 MHz, con un camino crítico de la
    Debug Unit);
  - sacar ese contador del camino.
- **Decisión:** lo segundo. `dmem_used` se actualiza un ciclo después,
  con un registro de por medio y un estado más en STEP. Es un cambio chico
  y el camino crítico que se analiza pasa a ser el del procesador.
- Detalle, alternativas y por qué el retraso es seguro: arquitectura.md
  §4.4.1. Los 24 testbenches pasan, y quitar el estado nuevo hace fallar
  `tb_system_top`.

**4. De nuevo a 100 MHz**, con el cambio.
- WNS = −0,102 ns (antes −1,091), TNS = −0,102 ns, **1** endpoint fallido
  (antes 81).
- El peor camino ahora es del core: EX/MEM → forwarding → ALU → byte-enable
  del store → `WEA` de la dmem, con 11 niveles.
- Estimación: ~99 MHz (`1 / 10,10 ns`).

**5. 98 MHz** (49 / 5 / 10, VCO 980 MHz).
- Se eligió por estar ~1 % por debajo de la estimación y tener poco error
  de baudios (+0,32 %).
- Falló, y por más que a 100 MHz: WNS = −0,409 ns, 19 endpoints fallidos.
  El reporte explica por qué:
  - el mismo tipo de camino midió 9,97 ns contra 9,50 ns en el build
    anterior: la ubicación cambia entre builds;
  - con D = 5 la incertidumbre del reloj subió de 0,074 a 0,127 ns.
- Con esta ubicación, el máximo era ~94 MHz (`1 / 10,61 ns`).
- **Conclusión:** el slack de un build no predice el de otro. El máximo
  hay que confirmarlo con un build que cumpla, y conviene un D chico.

**6. 94,444 MHz** (17 / 2 / 9, VCO 850 MHz).
- Se listaron las configuraciones del MMCM entre 91 y 96,5 MHz con
  D ≤ 3, con su error de baudios. Quedaron dos candidatas:
  - **94,444 MHz** (D = 2, +0,47 %), justo en el límite estimado;
  - **92,308 MHz** (D = 1 con el VCO al máximo, el menor jitter, +0,16 %),
    como reserva.
- Se probó primero la más alta, porque un build que cumple garantiza el
  funcionamiento a esa frecuencia aunque el margen sea chico.
- Resultado: **WNS = +0,216 ns, WHS = +0,095 ns, 0 endpoints fallidos**,
  incertidumbre 0,093 ns. El peor camino pasó a terminar en la dirección
  de la imem (§4.1).
- **Decisión:** quedarse en 94,444 MHz. Probar 96,296 MHz ganaría ~2 % y
  podría fallar por la variación entre builds.
- Se dejó como valor por defecto de `basys3_top`, y el build por defecto
  reproduce el mismo bitstream (§2).

**7. Prueba en la placa a 94,444 MHz.**
- Los 8 programas dieron igual al ISS.
- Como esos resultados son iguales a cualquier frecuencia, se comprobó
  aparte que la placa corría de verdad el bitstream nuevo, midiendo la
  duración de un RUN que termina por TIMEOUT (§7.1).

### 5.2 Barrido

| Frecuencia | M / D / O | VCO | WNS | Endpoints fallidos | Incertidumbre | Resultado |
|---|---|---|---|---|---|---|
| 50 MHz | 10 / 1 / 20 | 1000 MHz | +4,498 ns | 0 | 0,082 ns | cumple (puesta en marcha, antes de §4.4.1) |
| 100 MHz | 10 / 1 / 10 | 1000 MHz | −0,102 ns | 1 | 0,074 ns | falla |
| 98 MHz | 49 / 5 / 10 | 980 MHz | −0,409 ns | 19 | 0,127 ns | falla |
| **94,444 MHz** | **17 / 2 / 9** | **850 MHz** | **+0,216 ns** | **0** | 0,093 ns | **cumple** |

(El build de 100 MHz anterior a §4.4.1 dio −1,091 ns; ver §4.2.)

**Decisión:** 94,444 MHz (período 10,588 ns), la mayor frecuencia probada que
cumple timing.

**Alternativas:** probar 96,296 MHz (M = 26, D = 3, O = 9): el slack de
+0,216 ns sugiere que esa ubicación llegaría a ~96,4 MHz, pero la variación
entre builds (abajo) hace que pueda fallar. Se decidió no seguir buscando:
un build que cumple timing garantiza el funcionamiento a esa frecuencia, y
la ganancia sería de un 2 %.

**Lo que mostró el barrido:**
- **El slack de un build no predice el de otro.** Con WNS = −0,102 ns a
  100 MHz, el máximo parecía ~99 MHz, pero a 98 MHz el resultado fue peor
  (−0,409 ns). La ubicación cambia con cada restricción de reloj: el mismo
  tipo de camino midió 9,50 ns en un build y 9,97 ns en el otro, casi 0,5 ns
  de diferencia. Además, con un reloj holgado Vivado deja de optimizar en
  cuanto cumple: a 50 MHz el peor camino midió 15,2 ns. Por eso el
  máximo hay que confirmarlo con un build que cumpla, no estimarlo.
- **La configuración del MMCM cambia el jitter.** Con D = 5 el comparador de
  fase trabaja a 20 MHz y la incertidumbre subió a 0,127 ns; con D = 1 o 2
  queda en 0,07-0,09 ns. A igual frecuencia conviene un D chico y un VCO
  alto.

### 5.3 Error de baudios

La UART de TP2 usa un divisor entero, `DIV = CLK_FREQ_HZ / (115200 · 16)`
truncado:

| Frecuencia | DIV | Baudios reales | Error |
|---|---|---|---|
| 100 MHz | 54 | 115 741 | +0,47 % |
| 50 MHz | 27 | 115 741 | +0,47 % |
| 94,444 MHz | 51 | 115 741 | +0,47 % |

Las tres dan el mismo error, y no es casualidad: 50 = 100 / 2 y
94,444 = 100 · 17/18, y 54 es divisible por 2 y por 18, así que el divisor
escala exacto (27 = 54 / 2, 51 = 54 · 17/18). El error queda muy por debajo
del ~2 % tolerable, así que no hizo falta el divisor fraccional previsto en
arquitectura.md §8.
En el barrido se descartaron frecuencias con más error (98,4 MHz da +0,77 %,
97,5 MHz +1,73 %).

### 5.4 Efectos en el resto del sistema

- `MAX_CYCLES = 1 000 000` son 10,6 ms a 94,444 MHz (eran 10 ms a 100 MHz).
- El timeout entre bytes de la Debug Unit es `CLK_FREQ_HZ / 100` ciclos, así
  que sigue siendo 10 ms.
- El borrado de la dmem (1024 ciclos) dura ~10,8 µs.

---

## 6. Skew del reloj

**Qué es:** la diferencia entre los momentos en que el mismo flanco de reloj
llega al flip-flop de origen y al de destino de un camino. Vivado lo informa
como `DCD − SCD + CPR` (retardo del reloj en destino menos en origen, más la
eliminación del pesimismo de la parte común del árbol).

**Consecuencias:**
- **Setup:** si el reloj llega antes al destino (skew negativo), el dato
  tiene menos tiempo para llegar: el período útil se acorta.
- **Hold:** si el reloj llega después al destino (skew positivo), el dato
  nuevo del origen puede pisar al viejo antes de que el destino lo capture.
  Es el caso peligroso, porque no se arregla bajando la frecuencia.

**Medición** (peor camino hacia cada uno de los 5592 endpoints de `clk_sys`,
sobre el diseño ruteado a 94,444 MHz):

| Análisis | Mínimo | Máximo | Promedio |
|---|---|---|---|
| Setup (esquina lenta) | −0,198 ns | +0,055 ns | −0,069 ns |
| Hold (esquina rápida) | −0,032 ns | +0,313 ns | +0,082 ns |

- En el **camino crítico** el skew es 0,012 ns: no influye.
- En setup, el skew le quita como mucho 0,2 ns a un camino (2 % del
  período) y casi siempre mucho menos.
- En hold, el peor caso es +0,313 ns, y 1082 caminos superan los 0,2 ns.
  Igual **todos cumplen hold**: el
  peor slack de hold es +0,095 ns (de `ex_mem_reg` a `mem_wb_reg`, con skew
  de 0,260 ns). El router agrega retardo donde hace falta para compensar.

**Por qué es tan chico:**
- Un solo dominio de reloj distribuido por un único BUFG, la red global
  dedicada del Artix-7, diseñada para tener poco skew.
- El reloj no pasa por lógica (sin gating ni divisores); el enable global
  actúa sobre los CE de los flip-flops y de las BRAM (arquitectura.md §6).
- El MMCM compensa el retardo del árbol (realimentación por BUFG, §1): en el
  camino crítico el reloj llega a los flip-flops entre 1 y 1,5 ns *antes*
  que al pin de la placa (`SCD = −0,964 ns`, `DCD = −1,515 ns` respecto de
  sus flancos), y como origen y destino están compensados por igual, la
  diferencia que importa (el skew) es de 0,012 ns.

En los reportes aparecen skews de −1,48 ns en `btn_reset → rst_sync` y
`uart_rxd → rx_q1`. No son skew entre flip-flops: el origen es un pin
asíncrono sin reloj, son caminos con `set_false_path` y slack infinito, y
los sincronizadores 2FF existen justamente por eso.

**Incertidumbre del reloj** (aparte del skew): 0,093 ns en el camino
crítico, que salen del jitter del sistema (0,071 ns) y del jitter discreto
del MMCM (0,172 ns), combinados como `√(TSJ² + DJ²) / 2`.

---

## 7. Prueba en la placa

Con `cli.py --port COM3`, cada programa de `asm/` se carga, se corre y se
compara con el ISS (`-c "load ..." -c run -c check`): motivo de detención,
ciclos, los 32 registros y la dmem.

| Programa | Resultado | 50 MHz | 94,444 MHz |
|---|---|---|---|
| `alu` | HALT, 29 ciclos | igual al ISS | igual al ISS |
| `branches` | HALT, 41 ciclos | igual al ISS | igual al ISS |
| `forwarding` | HALT, 21 ciclos | igual al ISS | igual al ISS |
| `jumps` | HALT, 22 ciclos | igual al ISS | igual al ISS |
| `load_use` | HALT, 22 ciclos | igual al ISS | igual al ISS |
| `loadstore` | HALT, 26 ciclos | igual al ISS | igual al ISS |
| `loop` | HALT, 78 ciclos | igual al ISS | igual al ISS |
| `no_halt` | OOR, 8 ciclos | igual al ISS | igual al ISS |

La prueba a 50 MHz se hizo antes del cambio de §4.4.1, y la de 94,444 MHz
con el diseño final.

### 7.1 ¿La placa corre de verdad a la frecuencia nueva?

Estos resultados no distinguen los dos bitstreams: los ciclos no dependen
de la frecuencia y el error de baudios es el mismo en ambos (§5.3). Por eso
se midió el reloj desde el host con un script descartable, que no quedó en
el repo:

- Carga un programa que salta a sí mismo para siempre (`jal x0, 0`), así
  que cada RUN termina por TIMEOUT después de 1 000 005 ciclos.
- La respuesta sale recién cuando termina la ejecución, así que
  `t_RUN ≥ t_pedido + ciclos / f + t_respuesta`. Las transferencias por UART
  son fijas: 5 bytes a 115 200 y 209 bytes a 115 741 baudios suman
  18,49 ms. La latencia del USB solo puede sumar.
- En 15 RUN, el más lento tardó 32,09 ms. Entonces la ejecución duró como
  mucho 13,60 ms, y **f ≥ 73,5 MHz**. A 50 MHz cada RUN habría tardado como
  mínimo 38,49 ms.

Solo existen dos bitstreams, de 50 y 94,444 MHz (los builds de 98 y
100 MHz no llegaron al bitstream), así que la placa corría el de
94,444 MHz.

Restar el tiempo de un DUMP para medir la frecuencia exacta no funciona:
el chip USB-serie (FTDI) entrega los datos con un temporizador de latencia
de 16 ms, y DUMP y RUN tardan los dos ~32 ms. El método solo da una cota
inferior, pero alcanza para descartar 50 MHz.
