.option norvc
.section .text
.globl _start
_start:
    addi x1, zero, 1
    addi x2, zero, 2
    addi x3, zero, 3
    addi x4, zero, 4
    li   x7, 0x6000
    csrs mstatus, x7
    la   x10, scratch
    la   x29, tohost
    addi x28, zero, 1
    div  x6, x3, x4
    fadd.s f21, f1, f2
    mul  x8, x1, x2
    fadd.s f22, f1, f2
    fadd.s f23, f1, f2
    fadd.s f24, f1, f2
    add  x20, x8, x6

pass:
    sd   x28, 0(x29)
1:  j    1b
.section .data
scratch: .quad 0
