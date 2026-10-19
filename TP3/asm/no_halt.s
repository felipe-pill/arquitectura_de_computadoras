# Program without HALT: execution falls off the end of the loaded program.
# The hardware stops with halt_reason = OOR and PC = 0x0c (first address
# past the program), after N + 4 = 4 + 4 = 8 cycles (the OOR slot counts
# as the 4th). Expected: x3 = 3.
        addi  x1, x0, 1
        addi  x2, x0, 2
        add   x3, x1, x2
