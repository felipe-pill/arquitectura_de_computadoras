# TP3 - Protocolo UART entre el host y la Debug Unit

Versión del protocolo: **1**. Diseñado en la fase 0; implementado en la
Debug Unit (fase 5) y en `TP3/py/protocol.py` (fase 6).

Este documento es **el único contrato** entre el host en Python (`TP3/py/`) y
la Debug Unit en Verilog (`TP3/src/debug_unit*.v`). Si un lado necesita algo
distinto, primero se cambia este archivo.

Alcance: solo los comandos que pide SPEC §5.5 (cargar programa, ejecución
continua, step, reset y volcado de estado), sin extras.

---

## 1. Capa física

- UART **115200 baudios, 8 bits de datos, sin paridad, 1 bit de stop (8N1)**,
  LSB primero (los módulos de TP2 sin cambios).
- Sin control de flujo por hardware.
- La Debug Unit no tiene FIFO de recepción: procesa cada byte en el ciclo en
  que llega, lo que sobra porque un byte dura ~8700 ciclos a 100 MHz.

## 2. Reglas generales

- **Endianness:** todo campo de más de un byte es **little-endian**, igual
  que RISC-V. En Python: `struct` con `"<"`.
- **Pedido-respuesta, de a uno (stop-and-wait):** el host envía un pedido y
  espera su respuesta antes de enviar el siguiente.
- Un pedido que llega mientras la Debug Unit está ocupada (incluido un RUN en
  curso) se **descarta sin respuesta**. Un RUN siempre termina solo, a más
  tardar por el límite de ciclos (arquitectura.md §5.4); si algo se cuelga
  igual, queda el botón de reset de la placa.
- **Toda trama completa y bien formada recibe exactamente una respuesta.**
  Las tramas incompletas (timeout entre bytes) o con error de framing UART se
  descartan en silencio; el host las detecta por su propio timeout.

## 3. Formato de trama

### 3.1 Pedido (host → FPGA)

| Offset | Tamaño | Campo | Valor |
|---|---|---|---|
| 0 | 1 | `SOF` | `0xA5` |
| 1 | 1 | `CMD` | código de comando (sección 4) |
| 2 | 2 | `LEN` | bytes de payload, u16 LE |
| 4 | `LEN` | `PAYLOAD` | según el comando |
| 4+`LEN` | 1 | `CHK` | checksum |

### 3.2 Respuesta (FPGA → host)

| Offset | Tamaño | Campo | Valor |
|---|---|---|---|
| 0 | 1 | `SOF` | `0x5A` |
| 1 | 1 | `RSP` | `CMD \| 0x80` si fue exitoso; `0xE1..0xE5` si hubo error |
| 2 | 2 | `LEN` | bytes de payload, u16 LE |
| 4 | `LEN` | `PAYLOAD` | según la respuesta |
| 4+`LEN` | 1 | `CHK` | checksum |

### 3.3 Checksum

Complemento a dos de la suma de 8 bits, como en Intel HEX. Cubre desde
`CMD`/`RSP` hasta el último byte del payload; **no** incluye el `SOF`:

```
CHK = (-(CMD + LEN_lo + LEN_hi + sum(PAYLOAD))) & 0xFF
```

Verificación: la suma de 8 bits de `CMD..CHK` debe dar `0x00`. En hardware es
un acumulador de 8 bits que tiene que terminar en 0.

```python
def frame(sof, code, payload=b""):
    body = bytes([code]) + struct.pack("<H", len(payload)) + payload
    return bytes([sof]) + body + bytes([(-sum(body)) & 0xFF])
```

**Alternativas:**
- XOR de 8 bits: no detecta dos errores en el mismo bit.
- CRC-8: más robusto, pero el canal USB-UART casi no tiene errores de bit; el
  riesgo real es perder bytes o desincronizarse, y eso ya lo cubren `LEN` y el
  timeout.
- Sin checksum: un LOAD corrupto se ejecutaría sin aviso.

### 3.4 Sincronización y recuperación

- El receptor busca `0xA5` y después cuenta exactamente `LEN` bytes de
  payload más el `CHK`. Un `0xA5` dentro del payload no confunde al parser.
- **Timeout entre bytes: 10 ms.** Si a mitad de trama pasan 10 ms sin un byte,
  la trama se descarta y el parser vuelve a buscar `SOF`. El host debe enviar
  cada trama de corrido (un solo `serial.write()`).
- Un byte con error de framing (stop bit en 0) aborta la trama en curso.
- Ante un timeout de respuesta, el host puede esperar > 10 ms y reenviar.
  `cli.py` no reintenta solo: informa el error y el usuario repite el
  comando.

**Alternativas:** un byte de escape o *byte stuffing* (SLIP/COBS) para que
`SOF` sea único. Hace la resincronización inmediata, pero complica el
receptor en hardware. Con stop-and-wait y timeout no hace falta.

## 4. Comandos

| CMD | Nombre | `LEN` del pedido | Respuesta OK |
|---|---|---|---|
| `0x01` | LOAD | 4·N, 1 ≤ N ≤ `IMEM_DEPTH` | `0x81` + N (u16) |
| `0x02` | RESET | 0 | `0x82` (sin payload) |
| `0x03` | RUN | 0 | `0x83` + STATE, **al terminar la ejecución** |
| `0x04` | STEP | 0 | `0x84` + STATE |
| `0x05` | DUMP | 0 | `0x85` + STATE |

### `0x01` LOAD
Payload: N palabras de instrucción de 32 bits, **cada una en little-endian**
(la misma imagen de bytes que tendría la memoria de un RISC-V), en orden de
dirección empezando en la palabra 0.

Secuencia en la Debug Unit:
1. **Al recibir el encabezado** valida `LEN`: tiene que ser múltiplo de 4, con
   4 ≤ `LEN` ≤ 4·`IMEM_DEPTH`. Si no, consume el resto de la trama sin
   escribir nada y responde `ERR_LENGTH`.
2. Si es válido, activa `core_rst`, pone `prog_valid = 0` y `prog_len = 0`, y
   escribe cada palabra en imem apenas tiene sus 4 bytes.
3. **Al terminar la trama**, verifica el checksum:
   - **OK:** `prog_len = N`, `prog_valid = 1`, hace el reset completo (ver
     RESET) y responde `0x81` con payload `N` (u16).
   - **Error:** responde `ERR_CHECKSUM`. `prog_valid` queda en 0, así que RUN
     y STEP responden `ERR_NO_PROGRAM` hasta un LOAD correcto. La imem puede
     quedar a medio escribir, pero con `prog_len = 0` nunca se ejecuta.

La imem no se borra: las palabras desde N en adelante conservan lo que
tenían, pero el límite OOR impide ejecutarlas.

### `0x02` RESET
Reinicia la ejecución **sin tocar el programa**:
- `core_rst`: PC = 0, pipeline vacío, x1..x31 = 0, `halted`/`halting`/motivo
  y `cycle_cnt` en 0;
- borra toda la dmem y pone `dmem_used = 0`.

Después el core queda congelado (`core_en = 0`) esperando RUN o STEP.

### `0x03` RUN
Ejecuta en modo continuo (`core_en = 1` en cada ciclo) hasta que el core
levanta `halted`: `ebreak`, ILLEGAL, OOR o TIMEOUT, con el pipeline ya vacío.
**Recién entonces** responde `0x83` + STATE. No hay respuesta inmediata.

Continúa desde el estado actual: se puede hacer STEP varias veces y después
RUN. Como el límite de ciclos se cuenta desde el reset, un RUN nunca dura más
que `MAX_CYCLES` ciclos (10 ms a 100 MHz), así que el host puede esperar la
respuesta con el mismo timeout que el resto de los comandos.

### `0x04` STEP
Avanza **exactamente un ciclo de reloj** (un pulso de `core_en`) y responde
`0x84` + STATE con el estado posterior. Si ese ciclo completa el drenaje, el
volcado ya muestra `halted = 1`.

### `0x05` DUMP
Responde `0x85` + STATE sin avanzar nada. También le sirve al host para
verificar la conexión al abrir el puerto.

## 5. Errores

Payload de toda respuesta de error: **1 byte = el `CMD` del pedido** que la
causó.

| RSP | Nombre | Causa |
|---|---|---|
| `0xE1` | `ERR_CHECKSUM` | el checksum del pedido no da 0 |
| `0xE2` | `ERR_UNKNOWN_CMD` | `CMD` no definido |
| `0xE3` | `ERR_LENGTH` | `LEN` inválido para el comando |
| `0xE4` | `ERR_HALTED` | STEP o RUN con el core ya `halted` (hace falta RESET o LOAD) |
| `0xE5` | `ERR_NO_PROGRAM` | STEP o RUN sin un LOAD válido |

Orden de evaluación al terminar la trama: checksum → comando conocido →
`LEN` → estado. LOAD es la excepción: `LEN` se evalúa **al recibir el
encabezado**, porque escribe imem mientras llegan los bytes.

## 6. Volcado de estado (STATE)

Payload de las respuestas `0x83`, `0x84` y `0x85`. Largo total
**`204 + 4·dmem_used` bytes** (máximo 4300 con 4 KiB de dmem).

| Offset | Tamaño | Contenido |
|---|---|---|
| 0 | 12 | bloque de estado (6.1) |
| 12 | 64 | PC y registros de pipeline (6.2) = `dbg_core_vec` |
| 76 | 128 | x0..x31, u32 LE cada uno (x0 siempre 0) |
| 204 | 4·`dmem_used` | dmem palabras `0 .. dmem_used-1`, u32 LE |

### 6.1 Bloque de estado (offset 0)

| Offset | Tamaño | Campo |
|---|---|---|
| 0 | 1 | `flags`: bit0 `halted`, bit1 `halting` (drenando), bit2 `prog_valid`, bits 7..3 = 0 |
| 1 | 1 | `halt_reason`: 0 NONE, 1 HALT, 2 ILLEGAL, 3 OOR, 4 TIMEOUT |
| 2 | 2 | `prog_len` (palabras) u16 |
| 4 | 4 | `cycle_cnt` u32: ciclos habilitados desde el reset |
| 8 | 2 | `dmem_used` u16: palabras volcadas en el offset 204 |
| 10 | 2 | reservado (0) |

### 6.2 PC y registros de pipeline (offset 12, 64 bytes)

Cada campo es u32 LE. Los campos `ctrl` son bitfields; los bits no listados
valen 0. Una **burbuja** tiene `valid = 0` y todos los bits de control en 0;
en IF/ID, además, `instr = 0x00000013`.

| Offset | Registro | Campo |
|---|---|---|
| 12 | - | `PC`: dirección de la instrucción en IF |
| 16 | IF/ID | `pc` |
| 20 | IF/ID | `instr` |
| 24 | IF/ID | `ctrl` |
| 28 | ID/EX | `pc` |
| 32 | ID/EX | `rs1_data` (leído en ID, **antes** del forwarding) |
| 36 | ID/EX | `rs2_data` (ídem) |
| 40 | ID/EX | `imm` |
| 44 | ID/EX | `ctrl` |
| 48 | EX/MEM | `pc` |
| 52 | EX/MEM | `result` (resultado de la ALU / dirección / pc+4) |
| 56 | EX/MEM | `store_data` (rs2 forwardeado, sin alinear) |
| 60 | EX/MEM | `ctrl` |
| 64 | MEM/WB | `pc` |
| 68 | MEM/WB | `wb_data` (valor que se escribe en `rd`) |
| 72 | MEM/WB | `ctrl` |

**IF/ID `ctrl`** (offset 24)

| Bits | Campo |
|---|---|
| 0 | `valid` |
| 3..1 | `stop_code` (0, o 3 OOR / 4 TIMEOUT) |

**ID/EX `ctrl`** (offset 44)

| Bits | Campo |
|---|---|
| 4..0 | `rs1` (efectivo) |
| 9..5 | `rs2` (efectivo) |
| 14..10 | `rd` |
| 18..15 | `alu_op` = `{alt, funct3}` |
| 19 | `alu_src` (1 = inmediato) |
| 20 | `link` (resultado = pc+4) |
| 21 | `reg_write` |
| 22 | `mem_read` |
| 23 | `mem_write` |
| 26..24 | `funct3` |
| 27 | `branch` |
| 28 | `jalr` |
| 29 | `is_halt` |
| 30 | `valid` |

**EX/MEM `ctrl`** (offset 60)

| Bits | Campo |
|---|---|
| 4..0 | `rd` |
| 5 | `reg_write` |
| 6 | `mem_read` |
| 7 | `mem_write` |
| 10..8 | `funct3` |
| 11 | `is_halt` |
| 12 | `valid` |

**MEM/WB `ctrl`** (offset 72)

| Bits | Campo |
|---|---|
| 4..0 | `rd` |
| 5 | `reg_write` |
| 6 | `mem_read` |
| 7 | `is_halt` |
| 8 | `valid` |

Notas para el host:
- Con el `pc` de cada etapa y el programa cargado, la CLI puede mostrar qué
  instrucción hay en cada etapa.
- Con los `rd`/`rs`/`reg_write` de los registros puede deducir qué forwarding,
  stall o flush va a ocurrir en el próximo ciclo, sin que el hardware lo
  envíe.

En hardware, `dbg_core_vec[8*k +: 8]` es el byte `12 + k` del STATE.

## 7. Ejemplos (bytes en hex)

Checksums verificados con la función `frame()` de 3.3.

| Qué | Bytes |
|---|---|
| LOAD de `addi x1,x0,5` (`0x00500093`) + `ebreak` (`0x00100073`) | `A5 01 08 00 93 00 50 00 73 00 10 00 91` |
| → respuesta (N = 2) | `5A 81 02 00 02 00 7B` |
| LOAD con checksum incorrecto → | `5A E1 01 00 01 1D` |
| RESET | `A5 02 00 00 FE` |
| → respuesta | `5A 82 00 00 7E` |
| RUN | `A5 03 00 00 FD` |
| STEP | `A5 04 00 00 FC` |
| → si ya está halted | `5A E4 01 00 04 17` |
| DUMP | `A5 05 00 00 FB` |

Ejemplo de sesión: LOAD → RUN. Para el programa de 2 instrucciones de arriba,
la respuesta del RUN es `0x83` con un STATE de 204 bytes que contiene:
- `flags = 0x05` (halted, prog_valid), `halt_reason = 1`;
- `cycle_cnt = 6`, `dmem_used = 0`;
- `PC = 0x00000004` (el `ebreak`);
- x1 = 5;
- cuatro registros de pipeline en burbuja.

## 8. Tiempos de referencia (115200 baudios ≈ 11,5 KB/s)

| Operación | Bytes en el cable | Tiempo aprox. |
|---|---|---|
| STEP con `dmem_used = 0` | 5 + 209 | ~19 ms |
| STEP con `dmem_used = 64` | 5 + 465 | ~41 ms |
| LOAD de 1024 palabras | 4101 + 7 | ~0,36 s |
| STATE con dmem completa (4 KiB) | 4305 | ~0,37 s |

Timeout en el host: alcanza con 1 s para cualquier respuesta, RUN incluido
(la ejecución dura como máximo 10 ms más la transmisión del STATE). `cli.py`
usa 2 s por defecto (`--timeout`).

## 9. Decisiones de diseño del protocolo

| Decisión | Alternativas | Por qué |
|---|---|---|
| Trama uniforme `SOF CMD LEN PAYLOAD CHK` para todos los comandos | formato fijo por comando sin LEN (como en TP2) | un único parser en hardware; comandos desconocidos o con LEN inválido se saltean sin perder el sincronismo |
| SOF distinto por dirección (`A5`/`5A`) | el mismo SOF | en un log mezclado se distingue enseguida quién habla |
| LOAD escribe mientras recibe y valida al final | buffer de 4 KiB y escritura después del checksum | no hace falta otra BRAM; un LOAD fallido deja `prog_valid = 0`, así que nunca se ejecuta basura |
| RUN responde recién al terminar, con el STATE | ACK inmediato + aviso posterior | un solo mensaje y sin estados intermedios en el host; SPEC pide enviar el estado al terminar |
| Sin comandos durante RUN (sin BREAK) | BREAK / RESET que aborte | el límite de ciclos garantiza que todo RUN termina en ≤ 10 ms; no hace falta parsear comandos mientras corre |
| STEP = 1 ciclo y siempre con STATE | STEP con conteo N; STEP sin volcado y DUMP aparte | es literalmente lo que pide SPEC §5.3; ~20 ms por paso es interactivo |
| Volcado plano con offsets fijos (204 B + dmem) | TLV o un comando por sección | en hardware es un índice de bytes con un mux; en el host, un `struct.unpack` con offsets constantes |
| `dmem_used` = high-water mark | bitmap, volcado completo | ver arquitectura.md §4.4 |
| 115200 baudios | 230400/460800/921600 | el divisor entero de TP2 da +0,47 % de error a 100 MHz; a 921600 daría ~13 %. Las tramas son chicas, así que la velocidad no es el cuello de botella |
