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

    // Arguments to loader_main:
    //   x0 = QEMU's Linux FDT
    //   x1 = embedded XNU Mach-O
    //   x2 = Mach-O byte count
    //   x3 = architectural counter frequency
    ldr x1, =__kernel_image_start
    ldr x2, =__kernel_image_end
    sub x2, x2, x1
    mrs x3, cntfrq_el0
    bl loader_main

// If loader_main returns, park the primary core as well.
4:
    wfe
    b 4b

// Record the size of _start in the ELF symbol table.
.size _start, . - _start

// Enter XNU with:
//   x0 = physical entry address
//   x1 = physical boot_args address
.global enter_xnu
.type enter_xnu, %function

enter_xnu:
    mov x9, x0
    mov x10, x1

    // XNU starts with all asynchronous exceptions masked.
    msr daifset, #0xf

    // Make the copied instructions visible before branching to them.
    dsb sy
    ic iallu
    dsb sy
    isb

    mrs x11, CurrentEL
    cmp x11, #0x8
    b.eq 5f

    // This path permits reuse under firmware that already entered EL1.
    cmp x11, #0x4
    b.eq 6f
    b 7f

// QEMU raspi4b enters the loader at EL2h.
5:
    // Run EL1 as AArch64.
    mrs x11, hcr_el2
    orr x11, x11, #(1 << 31)
    msr hcr_el2, x11

    // Permit EL1 access to the physical counter and timer.
    mrs x11, cnthctl_el2
    orr x11, x11, #3
    msr cnthctl_el2, x11
    msr cntvoff_el2, xzr

    // Do not trap floating-point/SIMD access from EL1.
    msr cptr_el2, xzr

    // Give EL1h a valid temporary stack. XNU will replace it later.
    mov x11, sp
    msr sp_el1, x11

    // EL1h with D, A, I, and F masked.
    mov x11, #0x3c5
    msr spsr_el2, x11
    msr elr_el2, x9

    mov x0, x10
    isb
    eret

// Already executing at EL1.
6:
    mov x0, x10
    br x9

// Unsupported exception level.
7:
    wfe
    b 7b

.size enter_xnu, . - enter_xnu
