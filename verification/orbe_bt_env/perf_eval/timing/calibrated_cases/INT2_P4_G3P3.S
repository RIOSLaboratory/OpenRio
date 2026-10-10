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
    mul  x6, x3, x4
    addi x21, x0, 1
    ld   x8, 0(x10)
    addi x22, x21, 1
    addi x23, x22, 1
    addi x24, x23, 1
    addi x25, x24, 1
    addi x26, x25, 1
    add  x20, x6, x8

pass:
    sd   x28, 0(x29)
9:  wfi
    j    9b
.section .data
scratch: .quad 0
