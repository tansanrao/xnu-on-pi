.section .text.boot, "ax"

// Export _start so the linker can use it as the image entry point.
.global _start

// Mark _start as a function in the ELF symbol table.
.type _start, %function

_start:
    // Read the Multiprocessor Affinity Register. Its Aff0 field identifies
    // the individual CPU within the Cortex-A72 cluster.
    mrs x3, mpidr_el1

    // Extract Aff0 from bits [7:0].
    and x3, x3, #0xff

    // Core 0 continues at the forward label 1. Other cores fall through
    // into the secondary-core holding loop.
    cbz x3, 1f

// Hold secondary cores here.
//
// `0b` means the nearest preceding label named 0.
0:
    // Wait for an event
    wfe
    b 0b

// Primary-core initialization begins here.
//
// `1f` above refers to this next forward label named 1.
1:
    // Load the BSS address range defined by the linker script.
    ldr x1, =__bss_start
    ldr x2, =__bss_end

// Clear BSS in eight-byte chunks.
2:
    // Stop once the current address reaches or passes __bss_end.
    cmp x1, x2
    b.hs 3f

    // Store eight zero bytes, then advance x1 by eight.
    //
    // The linker script aligns the BSS boundaries so this cannot clear
    // beyond the intended region.
    str xzr, [x1], #8
    b 2b

// Establish the initial stack and enter Swift.
3:
    // Load the stack's upper address from the linker-script symbol.
    ldr x1, =__stack_top

    // AArch64 stacks grow downward, so execution starts at the top.
    // The linker script keeps this address 16-byte aligned as required
    // by the AArch64 procedure-call standard.
    mov sp, x1

    // Call the Embedded Swift entry point.
    //
    // QEMU placed the DTB pointer in x0, and the C calling convention passes it
    // as loader_main's first argument.
    bl loader_main

// If loader_main returns, park the primary core as well.
4:
    wfe
    b 4b

// Record the size of _start in the ELF symbol table.
.size _start, . - _start
