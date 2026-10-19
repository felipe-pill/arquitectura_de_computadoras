# Small loop: partial sums of 1..10 stored in an array at 0x80, final sum at 0.
# Expected: x1=10 x2=10 x3=55 x4=0xa8; [0x00]=55, [0x80..0xa4]=1,3,6,...,55.
# N = 4 + 10*5 + 2 = 56, 9 taken branches -> 56 + 4 + 18 = 78 cycles.
        addi  x1, x0, 0         # i
        addi  x2, x0, 10        # n
        addi  x3, x0, 0         # sum
        addi  x4, x0, 0x80      # array pointer
loop:
        addi  x1, x1, 1
        add   x3, x3, x1
        sw    x3, 0(x4)
        addi  x4, x4, 4
        bne   x1, x2, loop
        sw    x3, 0(x0)
        ebreak
