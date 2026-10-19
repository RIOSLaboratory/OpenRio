    .option norvc
    .section .text
    .globl _start
_start:
    addi x1, zero, 1
    addi x3, zero, 3
    la   x12, scratch
    li   x7, 0x6000
    csrs mstatus, x7
    la   x29, tohost
    addi x28, zero, 1
    la   x11, JT
    li   x12, 2
LOOP:
    mv   x10, x11
    jalr x5, 0(x10)
JT:
    add  x6, x5, x3
    addi x12, x12, -1
    bne  x12, x0, LOOP
pass:
    sd   x28, 0(x29)
1:  j    1b
.section .data
scratch: .quad 0
