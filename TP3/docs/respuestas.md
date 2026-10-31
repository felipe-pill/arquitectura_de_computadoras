# TP3 - Respuestas a las preguntas del enunciado (SPEC §8)

Cada respuesta es corta y apunta a la sección donde está el detalle.
Documentos: [arquitectura.md](arquitectura.md), [protocol.md](protocol.md),
[timing.md](timing.md), [verificacion.md](verificacion.md).

---

## 1. Al reprogramar, ¿hay que borrar la memoria de datos?

**Estrictamente no, pero el diseño la borra**, en cada LOAD y cada RESET
(y en el reset de placa).

- Un programa correcto inicializa lo que lee, así que la dmem vieja no
  debería cambiar su resultado. Pero un programa que lee una posición antes
  de escribirla vería datos del programa anterior, y el resultado dependería
  de qué se corrió antes.
- Borrarla hace que cada ejecución sea reproducible y coincida con el ISS,
  que arranca con todo en cero. Así se pueden comparar los volcados de la
  placa automáticamente (`check` en la CLI).
- También le da sentido a la "memoria usada": el high-water mark
  (`dmem_used`) vuelve a 0 y solo cuenta lo que escribió el programa actual
  (arquitectura.md §4.4).
- Costo: la Debug Unit recorre las 1024 palabras por el puerto A con el core
  en reset: 1024 ciclos, ~10,8 µs a 94,444 MHz, menos que el tiempo de un
  byte de UART (arquitectura.md §6.3, timing.md §5.4).

## 2. ¿Y los registros?

**Mismo criterio: no es obligatorio, pero se borran.** `core_rst` (RESET,
LOAD y reset de placa) pone x1..x31 en 0; x0 es 0 siempre.

- RISC-V no define el valor inicial de los registros, así que un programa
  no debería depender de él. Pero si no se borran, un programa que usa un
  registro sin inicializarlo daría resultados distintos según el programa
  anterior.
- Con todo en 0 el estado inicial coincide con el ISS. Eso incluye `sp`: no
  se inicializa a un tope de pila, porque los programas de prueba no la usan
  (arquitectura.md §6.3).
- El banco es de flip-flops con reset síncrono, así que borrarlo es gratis:
  ocurre en el mismo ciclo de reset (arquitectura.md §4.5, §7).

## 3. ¿Hay que vaciar el pipeline?

**Sí, y es la única de estas que es imprescindible.**

- Si se reprograma o se resetea a mitad de ejecución (por ejemplo, después
  de algunos STEP), los registros de pipeline contienen instrucciones del
  programa anterior. Sin vaciarlos, esas instrucciones seguirían avanzando y
  escribirían registros y dmem del programa nuevo, o un salto en EX
  redirigiría el PC.
- `core_rst` pone el PC en 0 y los cuatro registros de pipeline en burbuja
  (todo el control en 0). También reinicia el estado de HALT (`halting`,
  `halted`, `halt_reason`) y `cycle_cnt` (arquitectura.md §3.4, §6.3).
- Después de un HALT el pipeline ya está vacío por diseño (invariante de
  arquitectura.md §5.3), pero igual hace falta el reset para bajar `halted`
  y volver el PC a 0.
- Está verificado: `tb_cpu_step` aplica un reset en un ciclo aleatorio de
  cada uno de los 104 programas y vuelve a correrlo completo, y el resultado
  coincide con el ISS (verificacion.md §5.1). `tb_system_top` hace lo mismo
  por UART con `loadstore` (verificacion.md §6.2).

## 4. ¿Y la memoria de programa?

**No.** LOAD sobrescribe las palabras `0..N-1` y no toca el resto.

- Las palabras desde `N` en adelante conservan el programa anterior, pero
  nunca se ejecutan: un fetch con `PC >= 4·prog_len` se convierte en una
  detención OOR (pregunta 5).
- Borrarla obligaría a escribir las 1024 palabras en cada LOAD, sin ganar
  nada.
- Un LOAD con checksum incorrecto puede dejar la imem a medio escribir, pero
  deja `prog_valid = 0` y `prog_len = 0`: RUN y STEP responden
  `ERR_NO_PROGRAM` hasta un LOAD correcto (protocol.md §4).
- Está verificado: `tb_cpu_core` carga cada programa sobre el anterior sin
  borrar la imem, y OOR tiene que detenerlo antes de llegar a los restos
  (verificacion.md §4.2).

## 5. ¿Qué pasa si la memoria de programa no tiene instrucción de parada?

Sin protección, el PC seguiría avanzando más allá del programa: ejecutaría
restos de programas anteriores o ceros, y al pasar los 4 KiB volvería a la
dirección 0 por aliasing. RUN no terminaría nunca y el host no recibiría
respuesta.

El hardware tiene **dos salvaguardas**, que usan el mismo mecanismo que un
`ebreak` (drenaje, pipeline vacío, `halted` y volcado del estado), con el
motivo en `halt_reason` (arquitectura.md §5.1, §5.4):

1. **OOR** (`halt_reason = 3`): un fetch con `PC >= 4·prog_len` (fuera del
   programa cargado) se detiene. Cubre "caerse del final" y los saltos fuera
   del programa, sin detener por fetches en el camino equivocado de un salto.
2. **TIMEOUT** (`halt_reason = 4`): cuando `cycle_cnt >= MAX_CYCLES`
   (1 000 000 ciclos, 10,6 ms a 94,444 MHz) se detiene en el siguiente
   fetch. Cubre los bucles infinitos dentro del programa.

Además, una instrucción ilegal también detiene la ejecución (ILLEGAL,
arquitectura.md §2.2); entre otras, `0x00000000`.

Como consecuencia, **todo RUN termina** y el protocolo no necesita un
comando para interrumpirlo. Ejemplos: `no_halt.s` termina por OOR en 8
ciclos, en simulación y en la placa (timing.md §7), y un `jal x0, 0` termina
por TIMEOUT (timing.md §7.1).

## 6. ¿Cuál es el camino crítico del sistema?

A 94,444 MHz (timing.md §4.1):

    MEM/WB → selección de forwarding → operando de la ALU → sumador de 32 bits
           → destino de jalr/branch → mux de next_pc → dirección de la imem (BRAM)

- Origen `u_core/u_mem_wb/ctrl_reg[5]`, destino
  `u_imem/mem_reg/ADDRBWRADDR[11]`.
- 9,726 ns de datos (26 % lógica, 74 % ruteo), 12 niveles de lógica
  (3 CARRY4, 9 LUT), slack +0,216 ns sobre un período de 10,588 ns.

Es consecuencia de usar BRAM síncrona direccionada un ciclo antes
(arquitectura.md §4.2): la imem recibe `next_pc`, que en un salto tomado
sale de la ALU en EX, así que forwarding, ALU y setup de la BRAM caen en el
mismo ciclo. Una variante del mismo recorrido (EX/MEM → forwarding → ALU →
byte-enable del store → `WEA` de la dmem) fue la peor en el build de
100 MHz; cuál de las dos queda primera cambia entre builds (timing.md §4.2).

El primer camino crítico no era del procesador sino de la Debug Unit (el
high-water mark de la dmem, WNS −1,091 ns a 100 MHz). Se sacó del camino
actualizando `dmem_used` un ciclo después (arquitectura.md §4.4.1).

## 7. ¿Ese camino genera skew? ¿Qué consecuencias tiene?

**El skew no lo genera el camino de datos sino la red de reloj**, y en el
camino crítico es despreciable: **0,012 ns** (timing.md §6).

- **Por qué es chico:** un solo dominio de reloj, distribuido por un BUFG
  en la red global del Artix-7; el reloj no pasa por lógica (no hay gating
  ni divisores: el enable global usa los pines CE de flip-flops y BRAM); y
  el MMCM compensa el retardo del árbol con la realimentación por BUFG.
- **Consecuencias en general:**
  - en **setup**, un skew negativo acorta el período útil del camino;
  - en **hold**, un skew positivo puede hacer que el dato nuevo pise al
    viejo antes de que el destino lo capture, y eso no se arregla bajando
    la frecuencia.
- **Medido en todo el diseño** (5592 endpoints): en setup el skew le quita
  como mucho 0,198 ns a un camino (~2 % del período); en hold llega a
  +0,313 ns, pero todos los caminos cumplen (WHS = +0,095 ns) porque el
  router agrega retardo donde hace falta.
- Aparte del skew está la incertidumbre del reloj (jitter): 0,093 ns en el
  camino crítico.
- Los skews de −1,48 ns de los reportes (`btn_reset`, `uart_rxd`) no son
  entre flip-flops: son entradas asíncronas con `set_false_path`, que pasan
  por sincronizadores 2FF.

## 8. ¿Cuál es la frecuencia óptima de operación y cómo se eligió?

**94,444 MHz** (MMCM M = 17, D = 2, O = 9; VCO 850 MHz): la mayor frecuencia
probada que cumple timing, con WNS +0,216 ns, WHS +0,095 ns y 0 endpoints
fallidos (timing.md §5).

Cómo se llegó, en orden (timing.md §5.1):

| Paso | Frecuencia | WNS | Resultado |
|---|---|---|---|
| 1 | 100 MHz | −1,091 ns | falla; camino crítico en la Debug Unit |
| 2 | 50 MHz | +4,498 ns | puesta en marcha de la placa con margen |
| 3 | - | - | cambio de RTL: `dmem_used` un ciclo después |
| 4 | 100 MHz | −0,102 ns | falla por poco; estimación ~99 MHz |
| 5 | 98 MHz | −0,409 ns | falla: la ubicación cambió y D = 5 sube el jitter |
| 6 | **94,444 MHz** | **+0,216 ns** | **cumple** |

- En cada build se leyeron WNS, TNS, WHS y el peor camino; la frecuencia
  máxima de un build se estima como `1 / (T − WNS)`.
- Lección del barrido: el slack de un build no predice el de otro, porque
  la ubicación cambia con cada restricción. El máximo se confirma con un
  build que cumple, no se extrapola. Conviene un D chico (menos jitter).
- Restricción extra: el error de baudios de la UART (divisor entero). A
  94,444 MHz el divisor es 51 y el error +0,47 %, igual que a 100 MHz
  (timing.md §5.3).
- No se probó 96,296 MHz: la ganancia sería ~2 % y podría fallar por la
  variación entre builds.
- En la placa, los 8 programas de `asm/` dan igual al ISS a 94,444 MHz, y se
  comprobó que el bitstream cargado era el de esa frecuencia (timing.md §7).
