| 类别 | 指令 | cycles/iter | IPC | 推算 Latency (cycles) |
|:---|:---|:---|:---|:---|
| **ALU** | ADD | 1.02 | 1.009 | 1 |
| **BMU** | CLZ | 1.02 | 1.009 | 1 |
| **MUL** | MUL | 3.02 | 0.341 | 3 |
| **DIV** | DIV | 8.00 | 0.125 | 8 |
| **LOAD** | LD | 2.02 | 0.510 | 2 |
| **STORE** | SD+LD ¹ | 4.04 | 0.510 | 4 (roundtrip) |
| **STORE** | FSD+FLD ¹ | 4.04 | 0.510 | 4 (roundtrip) |
| **AMO** | AMOADD.D / AMOADD.W | 5.10 | 0.225 | 5 |
| **FADD** | FADD.D / FADD.S | 3.02 | 0.341 | 3 |
| **FMUL** | FMUL.D / FMUL.S | 4.02 | 0.256 | 4 |
| **FMA** | FMADD.D / FMADD.S | 4.02 | 0.256 | 4 |
| **FMISC** | FMIN.D/S / FSGNJ.D/S / FROUND.D/S | 3.02 | 0.341 | 3 |
| **FMISC** | FCVT.D.S / FCVT.D.H ² | 8.04 | 0.256 | 8 (roundtrip: FMISC×2+跨精度) |
| **FCLASS** | FCLASS.D/S + FMV ² | 4.02 | 0.505 | 4 (FMISC=3 + FMV_2F=1) |
| **FCMP** | FEQ.D/S + FMV ² | 4.02 | 0.505 | 4 (FCMP=3 + FMV_2F=1) |
| **FCVT** | FCVT.D.L / FCVT.L.D / FCVT.S.L / FCVT.L.S ² | 8.02 | 0.253 | 8 (FCVT_I2F=4 + FCVT_2I=4) |
| **FMV** | FMV.D.X+FMV.X.D / FMV.W.X+FMV.X.W ² | 2.02 | 1.005 | 2 (FMV_2F=1 + FMV_2I=1) |
| **FSQRT** | FSQRT.S | 12.10 | 0.095 | 12 |
| **FSQRT** | FSQRT.D | 18.10 | 0.064 | 18 |
| **FDIV** | FDIV.S | 20.00 | 0.050 | 20 |
| **FDIV** | FDIV.D | 23.00 | 0.044 | 23 |