/* Zig actually ignores ENTRY command in the linker script, but I keep it just in case. */
ENTRY(_start)

SECTIONS {
  . = 0x80200000;
  __kernel_page = .;

  .text :{
    KEEP(*(.text.boot));
    *(.text .text.*);
  }

  .rodata : ALIGN(8) {
    *(.rodata .rodata.*);
  }

  .data : ALIGN(8) {
    *(.data .data.*);
  }

  .bss : ALIGN(8) {
    __bss = .;
    *(.bss .bss.* .sbss .sbss.*);
    __bss_end = .;
  }

  /* stack pointer should be aligned to a 128-bit boundary */
  . = ALIGN(16);
  . += 128 * 1024;  /* 128KiB */
  __stack_top = .;

  . = ALIGN(4096);
  __free_ram = .;
  . += 64 * 1024 * 1024;  /* 64MiB */
  __free_ram_end = .;

  __kernel_page_end = .;
}
