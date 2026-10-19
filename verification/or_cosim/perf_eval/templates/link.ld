/* perf_eval case 链接脚本。
 *
 * 与 ISA model 的 ROM 配置 dpi/rivai_0x80000000_1core_rom.yaml 对齐：
 * 代码段从 0x80000000 起，并用 `.tohost` 提供 HTIF 退出用的字。
 *
 * 沿用 or-be-draft/isa_model_flow/isa_model_experiment/cases/link.ld 的约定
 * （那份已被 add / load / store / amoadd / fence 五个 case 验证过），
 * 不引入新语义。
 */

OUTPUT_ARCH(riscv)
ENTRY(_start)

PHDRS
{
  text PT_LOAD FLAGS(5);
  data PT_LOAD FLAGS(6);
}

SECTIONS
{
  . = 0x80000000;
  .text : { *(.text*) } :text
  .rodata : { *(.rodata*) } :text
  . = ALIGN(0x1000);
  .data : { *(.data*) } :data
  . = ALIGN(8);
  .tohost : { tohost = .; LONG(0); LONG(0); } :data
  .bss : { *(.bss*) *(COMMON) } :data
}
