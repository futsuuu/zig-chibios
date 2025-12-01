/* Zig actually ignores ENTRY section in the linker script, but I keep it just in case. */
ENTRY(_start)

SECTIONS {
  . = 0x80200000;
  __kernel_page = .;

  .text :{
    KEEP(*(.text.boot));
    *(.text .text.*);
  }

  .rodata : ALIGN(4) {
    *(.rodata .rodata.*);
  }

  .data : ALIGN(4) {
    *(.data .data.*);
  }

  .bss : ALIGN(4) {
    __bss = .;
    *(.bss .bss.* .sbss .sbss.*);
    __bss_end = .;
  }

  . = ALIGN(4);
  . += 128 * 1024;  /* 128KB */
  __stack_top = .;

  . = ALIGN(4096);
  __free_ram = .;
  . += 64 * 1024 * 1024;  /* 64MB */
  __free_ram_end = .;

  __kernel_page_end = .;
}
