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
    la   x11, pass
    la   x12, scratch
    la   x29, tohost
    addi x28, zero, 1
    mul  x10, x11, x1
    jalr x5, 0(x10)
pass:
    sd   x28, 0(x29)
9:  wfi
    j    9b
.section .data
scratch: .quad 0
