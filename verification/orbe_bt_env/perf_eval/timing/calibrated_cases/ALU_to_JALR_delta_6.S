.option norvc
.section .text
.globl _start
_start:
    addi x1, zero, 1
    addi x2, zero, 2
    addi x3, zero, 3
    addi x4, zero, 4
    la   x11, pass
    addi x10, x11, 0
    addi x13, x0, 1
    addi x14, x0, 1
    addi x15, x0, 1
    addi x16, x0, 1
    addi x17, x0, 1
    addi x18, x0, 1
    addi x19, x0, 1
    addi x20, x0, 1
    jalr x5, 0(x10)
pass:
    addi x28, zero, 1
    la   x29, tohost
    sd   x28, 0(x29)
9:  wfi
    j    9b
.section .data
scratch: .quad 0
