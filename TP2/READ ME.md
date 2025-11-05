# UART + ALU en Basys3

Este proyecto implementa la comunicación **PC ↔ FPGA (Basys3)** mediante UART y la integración de una **ALU de 8 bits** en el FPGA. El flujo de trabajo se divide en tres etapas: simulación, validación de comunicación, e interacción PC ↔ ALU.

---

## 1) Simulación UART — `tb_uart_loopback.v`

Este testbench permite verificar en simulación el correcto funcionamiento del módulo UART, haciendo un **loopback interno** (TX → RX dentro del FPGA).

> **Nota:** Para visualizar correctamente la trama UART en Vivado, ajustar el rango temporal de la simulación a **≥ 2 ms**, ya que la simulación usa tiempos más largos que el hardware real y los bits pueden no observarse en una ventana corta.

---

## 2) Eco en Hardware — `basys3_uart_echo.v` + `test_echo.py`

1. Sintetizar y cargar `basys3_uart_echo.v` en la Basys3.
2. Ejecutar desde PC:

```bash
python test_echo.py
````

Este script envía:

```
Hello Basys3!\r\n
```

y debe recibir exactamente la misma cadena.
Si esto ocurre, la comunicación **PC ↔ FPGA** vía UART está configurada correctamente.

---

## 3) Comunicación con ALU — `basys3_uart_alu.v` + `uart_alu_pc.py`

1. Cargar `basys3_uart_alu.v` en la Basys3.
2. Ejecutar en la PC:

```bash
python uart_alu_pc.py
```

Este script envía paquetes de 4 bytes hacia la FPGA:

```
[0xAA] [OP] [A] [B]
```

La FPGA:

* Captura los operandos y el opcode.
* Ejecuta la operación usando la **ALU de 8 bits**.
* Devuelve una respuesta formada por 3 bytes:

```
[0x55] [RESULT] [FLAGS]
```

Donde `FLAGS` codifica:

| bit | significado |
| --- | ----------- |
| 3   | overflow    |
| 2   | carry       |
| 1   | negative    |
| 0   | zero        |

### Ejemplo de salida esperada:

```
ADD 15+27    => RES=0x2A  FLAGS(ZNV C)=0000
OR  A5|0F    => RES=0xAF  FLAGS(ZNV C)=0100
SUB 10-20    => RES=0xF6  FLAGS(ZNV C)=0100
SRA 0x80>>2  => RES=0xE0  FLAGS(ZNV C)=0100
```

Esto confirma que:

* La ALU está recibiendo y ejecutando operaciones correctamente.
* La comunicación bidireccional UART está funcionando.
* Los flags que describen el resultado también se están transmitiendo correctamente.

---

## Parámetros UART (para pruebas manuales)

Si se desea usar una terminal serie:

| Parámetro    | Valor      |
| ------------ | ---------- |
| Baudrate     | **115200** |
| Data bits    | 8          |
| Paridad      | None       |
| Stop bits    | 1          |
| Flow control | None       |

---

## Archivos Principales

| Archivo                                                 | Descripción                                                 |
| ------------------------------------------------------- | ----------------------------------------------------------- |
| `uart.v` / `uart_rx.v` / `uart_tx.v` / `uart_baudgen.v` | Implementación UART completa                                |
| `myALU.v`                                               | Núcleo de ALU de 8 bits                                     |
| `tb_uart_loopback.v`                                    | Testbench en simulación                                     |
| `basys3_uart_echo.v`                                    | Prueba de eco en hardware                                   |
| `basys3_uart_alu.v`                                     | Integración UART + ALU en FPGA                              |
| `test_echo.py`                                          | Verificación de eco UART desde PC                           |
| `uart_alu_pc.py`                                        | Envío de operaciones ALU desde PC y recepción de resultados |

---
