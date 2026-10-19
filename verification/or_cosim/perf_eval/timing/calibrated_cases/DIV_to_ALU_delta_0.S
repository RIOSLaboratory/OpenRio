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
    div  x5, x1, x2
    add  x6, x5, x3
pass:
    sd   x28, 0(x29)
1:  j    1b
.section .data
scratch: .quad 0
