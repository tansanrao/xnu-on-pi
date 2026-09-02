.section .kernel, "a", %progbits

// KERNEL_PATH is supplied by the Makefile as a quoted absolute path.
.incbin KERNEL_PATH
