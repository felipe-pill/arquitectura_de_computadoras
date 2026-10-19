# Data hazards resolved by forwarding (no stalls expected).
        addi  x1, x0, 1         # x1 = 1
        addi  x2, x1, 1         # EX/MEM -> rs1                       x2 = 2
        addi  x3, x1, 2         # MEM/WB -> rs1                       x3 = 3
        add   x4, x2, x3        # rs1 from MEM/WB, rs2 from EX/MEM    x4 = 5
        add   x4, x4, x4        # both operands from EX/MEM           x4 = 10
        add   x4, x4, x1        # x4 in EX/MEM (10) and MEM/WB (5): newest wins, x4 = 11
        sub   x5, x4, x3        # x5 = 8
        sw    x5, 0(x0)         # store data forwarded               [0x00] = 8
        addi  x6, x0, 0x40      # x6 = 0x40
        sw    x5, 0(x6)         # store address forwarded            [0x40] = 8
        add   x7, x5, x0        # x7 = 8
        nop
        nop
        add   x8, x7, x7        # x7 written in WB while read in ID (regfile bypass), x8 = 16
        add   x0, x1, x1        # writes x0: must never be forwarded
        add   x9, x0, x1        # x9 = 1
        ebreak                  # dmem_used = 17
