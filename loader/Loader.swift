import _Volatile

// BCM2711 PL011 UART0 data register.
//
// Writing a byte to this register places it in the UART transmit FIFO.
private let uartData =
    VolatileMappedRegister<UInt32>(unsafeBitPattern: 0xfe201000)

// BCM2711 PL011 UART0 flag register.
//
// This exposes UART state such as whether the transmit FIFO is full.
private let uartFlags =
    VolatileMappedRegister<UInt32>(unsafeBitPattern: 0xfe201018)

// Bit 5 of the PL011 flag register is TXFF: Transmit FIFO Full.
private let transmitFIFOFull: UInt32 = 1 << 5

// Write one byte to UART0.
@inline(__always)
private func writeByte(_ byte: UInt8) {
    // Wait until the transmit FIFO has room for another byte.
    while uartFlags.load() & transmitFIFOFull != 0 {
    }

    // The PL011 data register is 32 bits wide, although only the low byte
    // contains the character being transmitted.
    uartData.store(UInt32(byte))
}

// Write a string to UART0.
private func write(_ string: StaticString) {
    // Expose the StaticString's UTF-8 storage as a read-only byte buffer.
    let bytes = UnsafeBufferPointer(
        start: string.utf8Start,
        count: string.utf8CodeUnitCount
    )

    for byte in bytes {
        // Convert LF into CRLF for conventional serial-terminal output.
        if byte == 0x0a {
            writeByte(0x0d)
        }

        writeByte(byte)
    }
}

// Check whether an address points to a Flattened Device Tree header.
private func hasFDTMagic(_ address: UnsafeRawPointer?) -> Bool {

    guard let address else {
        return false
    }

    // Interpret the beginning of the DTB as individual bytes.
    let bytes = address.assumingMemoryBound(to: UInt8.self)

    // Every FDT starts with the big-endian magic value 0xd00dfeed.
    return bytes[0] == 0xd0 && bytes[1] == 0x0d &&
        bytes[2] == 0xfe && bytes[3] == 0xed
}

// Export this function under the unmangled C symbol "loader_main" so the
// AArch64 startup assembly can invoke it with `bl loader_main`.
//
// Under the AArch64 boot convention used here, x0 contains the DTB address.
// The C calling convention maps x0 to this function's first argument.
@_cdecl("loader_main")
public func loaderMain(_ dtb: UnsafeRawPointer?) {
    write("Hello, world from the Embedded Swift XNU loader!\n")

    // Confirm that QEMU passed a plausible device-tree pointer in x0.
    if hasFDTMagic(dtb) {
        write("x0 contains a valid FDT.\n")
    } else {
        write("x0 does not contain a valid FDT.\n")
    }
}