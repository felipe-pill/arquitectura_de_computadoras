# Load-use hazards: exactly 3 one-cycle stalls in this program.
        addi  x1, x0, 42        # x1 = 42
        sw    x1, 0(x0)         # [0x00] = 42
        lw    x2, 0(x0)         # x2 = 42
        add   x3, x2, x2        # STALL (rs1 and rs2)                x3 = 84
        lw    x4, 0(x0)         # x4 = 42
        sw    x4, 4(x0)         # STALL (store data)                 [0x04] = 42
        lw    x5, 4(x0)         # x5 = 42
        addi  x6, x5, 1         # STALL                              x6 = 43
        lw    x7, 0(x0)         # x7 = 42
        nop
        add   x8, x7, x0        # no stall (one instruction apart)   x8 = 42
        lw    x0, 0(x0)         # load into x0
        add   x9, x0, x0        # no stall (rd = x0)                 x9 = 0
        lw    x1, 4(x0)         # x1 = 42
        ebreak                  # no stall: the rs2 field of ebreak is x1, but it reads no registers
