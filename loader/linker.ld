ENTRY(_start)

SECTIONS
{
    . = 0x00080000;

    .text : ALIGN(16) {
        KEEP(*(.text.boot))
        *(.text .text.*)
    }

    .rodata : ALIGN(16) {
        *(.rodata .rodata.*)
        *(.swift5_*)
        *(.swift_modhash)
    }

    .data : ALIGN(16) {
        *(.data .data.*)
    }

    .kernel : ALIGN(0x4000) {
        __kernel_image_start = .;
        KEEP(*(.kernel))
        __kernel_image_end = .;
    }

    .bss (NOLOAD) : ALIGN(16) {
        __bss_start = .;
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(16);
        __bss_end = .;
    }

    __stack_bottom = .;
    . += 0x4000;
    __stack_top = .;
    __loader_runtime_end = .;

    /DISCARD/ : {
        *(.comment)
        *(.note*)
        *(.eh_frame*)
    }
}

ASSERT(
    __loader_runtime_end <= 0x02000000,
    "loader runtime overlaps XNU at 0x02000000"
)
