.option norvc
.section .text
.globl _start
_start:
    addi x1, zero, 1
    addi x2, zero, 2
    addi x3, zero, 3
    addi x4, zero, 4
    li   x11, 0x6000
    csrs mstatus, x11
    la   x12, scratch
    div  x5, x1, x2
    ld   x13, 0(x12)
    fadd.s f13, f1, f2
    fadd.s f14, f1, f2
    fadd.s f15, f1, f2
    add  x6, x5, x3
pass:
    addi x28, zero, 1
    la   x29, tohost
    sd   x28, 0(x29)
9:  wfi
    j    9b
.section .data
scratch: .quad 0
