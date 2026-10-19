# jal / jalr: call and return, plain jump, jalr with rd == rs1 and an odd
# target (bit 0 is cleared).
# Expected: x1(ra)=8 x2=11 x6=0x30 x7=1 x10=0x24, final PC=0x34.
# Dynamic count N=11, 3 jal + 2 jalr -> 11 + 4 + 3 + 4 = 22 cycles.
        addi  x2, x0, 0         # 0x00
        jal   ra, func          # 0x04  ra = 8
        addi  x2, x2, 1         # 0x08  x2 = 11
        jal   x0, skip          # 0x0c
        addi  x2, x2, 100       # 0x10  skipped
func:
        addi  x2, x2, 10        # 0x14  x2 = 10
        jalr  x0, 0(ra)         # 0x18  return to 0x08
skip:
        addi  x10, x0, 45       # 0x1c  45 = 0x2d: odd target 0x2c | 1
        jalr  x10, 0(x10)       # 0x20  x10 = 0x24, jumps to 0x2c
        addi  x2, x2, 1000      # 0x24  skipped
        addi  x2, x2, 1000      # 0x28  skipped
        jal   x6, next          # 0x2c  x6 = 0x30
next:
        addi  x7, x0, 1         # 0x30
        ebreak                  # 0x34
