# beq/bne taken and not taken, forward and backward, load -> branch,
# and wrong-path ebreak / illegal words that must be flushed.
# Expected: x1=5 x2=5 x3=7 x4=7 x5=7 x6=0 x7=30, [0x00]=7.
# Dynamic count N=26, 5 taken branches, 1 load-use stall -> 41 cycles.
        addi  x1, x0, 5
        addi  x2, x0, 5
        addi  x3, x0, 0
        beq   x1, x2, eq_taken  # taken
        addi  x3, x3, 100       # flushed
        addi  x3, x3, 100       # flushed
eq_taken:
        addi  x3, x3, 1         # x3 = 1
        bne   x1, x2, wrong     # not taken
        addi  x3, x3, 2         # x3 = 3
        beq   x1, x0, wrong     # not taken
        addi  x4, x0, 7
        bne   x4, x1, ne_taken  # taken, rs1 forwarded from EX/MEM
        ebreak                  # wrong path: must not halt
wrong:
        addi  x3, x3, 1000
ne_taken:
        addi  x3, x3, 4         # x3 = 7
        sw    x3, 0(x0)
        lw    x5, 0(x0)         # x5 = 7
        beq   x5, x3, skip      # load-use stall, then taken
        .word 0x00000000        # wrong path illegal word: must not halt
skip:
        addi  x6, x0, 3         # loop counter
        addi  x7, x0, 0
back:
        addi  x7, x7, 10
        addi  x6, x6, -1
        bne   x6, x0, back      # backward: taken twice, then falls through
        ebreak
