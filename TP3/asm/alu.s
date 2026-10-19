# ALU operations: every R-type, every I-type ALU op, lui, and writes to x0.
# Expected values (hex) are in the comments; no load-use stalls, no branches.
        addi  x1, x0, 7         # x1  = 00000007
        addi  x2, x0, -3        # x2  = fffffffd
        add   x3, x1, x2        # x3  = 00000004
        sub   x4, x1, x2        # x4  = 0000000a
        and   x5, x1, x2        # x5  = 00000005
        or    x6, x1, x2        # x6  = ffffffff
        xor   x7, x1, x2        # x7  = fffffffa
        slt   x8, x2, x1        # x8  = 00000001  (-3 < 7 signed)
        sltu  x9, x2, x1        # x9  = 00000000  (0xfffffffd > 7 unsigned)
        addi  x10, x0, 4        # x10 = 00000004
        sll   x11, x1, x10      # x11 = 00000070
        srl   x12, x2, x10      # x12 = 0fffffff
        sra   x13, x2, x10      # x13 = ffffffff
        andi  x14, x2, 0xf0     # x14 = 000000f0
        ori   x15, x1, -16      # x15 = fffffff7
        xori  x16, x1, 0x7ff    # x16 = 000007f8
        slti  x17, x2, -2       # x17 = 00000001
        sltiu x18, x1, -1       # x18 = 00000001  (imm sign-extends to 0xffffffff)
        slli  x19, x1, 31       # x19 = 80000000
        srli  x20, x19, 31      # x20 = 00000001
        srai  x21, x19, 31      # x21 = ffffffff
        lui   x22, 0x12345      # x22 = 12345000
        addi  x22, x22, 0x678   # x22 = 12345678
        add   x0, x1, x1        # x0 stays 0
        ebreak
