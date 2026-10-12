.option norvc
.section .text
.globl _start
_start:
    addi x1, zero, 1
    addi x2, zero, 2
    addi x3, zero, 3
    addi x4, zero, 4
    la   x29, tohost
    addi x28, zero, 1
    mul  x5, x1, x2
    bne  x0, x0, 20f
20:
    bne  x0, x0, 21f
21:
    bne  x0, x0, 22f
22:
    bne  x0, x0, 23f
23:
    bne  x0, x0, 24f
24:
    add  x20, x5, x5
pass:
    sd   x28, 0(x29)
9:  wfi
    j    9b
.section .data
scratch: .quad 0
