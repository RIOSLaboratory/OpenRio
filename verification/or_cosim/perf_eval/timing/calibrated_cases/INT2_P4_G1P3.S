.option norvc
.section .text
.globl _start
_start:
    addi x1, zero, 1
    addi x2, zero, 2
    addi x3, zero, 3
    addi x4, zero, 4
    la   x10, scratch
    la   x29, tohost
    addi x28, zero, 1
    ld   x6, 0(x10)
    bne  x0, x0, 7f
7:
    mul  x8, x1, x2
    bne  x0, x0, 7f
7:
    bne  x0, x0, 7f
7:
    bne  x0, x0, 7f
7:
    bne  x0, x0, 7f
7:
    bne  x0, x0, 7f
7:
    add  x20, x6, x8

pass:
    sd   x28, 0(x29)
1:  j    1b
.section .data
scratch: .quad 0
