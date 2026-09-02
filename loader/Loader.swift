import _Volatile

// BCM2711 PL011 UART0 data register.
//
// Writing a byte to this register places it in the UART transmit FIFO.
private let uartData =
    VolatileMappedRegister<UInt32>(unsafeBitPattern: 0xfe20_1000)

// BCM2711 PL011 UART0 flag register.
//
// This exposes UART state such as whether the transmit FIFO is full.
private let uartFlags =
    VolatileMappedRegister<UInt32>(unsafeBitPattern: 0xfe20_1018)

// Bit 5 of the PL011 flag register is TXFF: Transmit FIFO Full.
private let transmitFIFOFull: UInt32 = 1 << 5

// Mach-O constants used to validate the embedded kernel and locate its
// loadable segments and initial program counter.
private let machMagic64: UInt32 = 0xfeed_facf
private let cpuTypeARM64: UInt32 = 0x0100_000c
private let machExecute: UInt32 = 0x2
private let loadSegment64: UInt32 = 0x19
private let loadUnixThread: UInt32 = 0x5

// Sizes and offsets from the published 64-bit Mach-O structures.
//
// unixThreadPCOffset is measured from the beginning of LC_UNIXTHREAD:
// load_command + flavor/count + ARM_THREAD_STATE64 registers preceding pc.
private let machHeader64Size: UInt64 = 32
private let segmentCommand64Size: UInt64 = 72
private let unixThreadPCOffset: UInt64 = 272
private let unixThreadMinimumSize: UInt64 = 288

// Keep the loader and its embedded copy of the kernel below 32 MiB. XNU's
// embedded arm64 layout places the Mach header 16 KiB after the managed-memory
// base; preserving that offset physically is required by its bootstrap block
// mappings.
private let kernelPhysicalBase: UInt64 = 0x0200_0000
private let kernelHeaderOffset: UInt64 = 0x4000
private let kernelPhysicalAddress: UInt64 =
    kernelPhysicalBase + kernelHeaderOffset

// The BCM2711 target uses the 4 KiB translation granule supported by the
// Cortex-A72. Boot metadata must follow the same page alignment.
private let kernelPageSize: UInt64 = 0x1000

// QEMU's raspi4b machine has a fixed 2 GiB RAM configuration.
private let physicalMemorySize: UInt64 = 0x8000_0000

// Reserve one XNU page for the synthetic Apple device tree. boot_argsSize is
// sizeof(boot_args) for this XNU release's arm64 ABI.
private let appleDeviceTreeMaximumSize: UInt64 = 0x4000
private let bootArgsSize: UInt64 = 1152

// Assembly performs the final EL2-to-EL1 transition. It never returns because
// successful execution continues at XNU's physical entry address.
@_silgen_name("enter_xnu")
private func enterXNU(
    _ entry: UInt,
    _ bootArgs: UInt
) -> Never

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

private func fail(_ message: StaticString) -> Never {
    write("loader: ")
    write(message)
    write("\n")

    // Spin because there is nowhere to return to.
    while true {
    }
}

@inline(__always)
private func rangeFits(
    offset: UInt64,
    length: UInt64,
    total: UInt64
) -> Bool {
    // avoiding offset + length overflow while validating data supplied by the
    // Mach-O image.
    offset <= total && length <= total - offset
}

@inline(__always)
private func alignUp(
    _ value: UInt64,
    to alignment: UInt64
) -> UInt64 {
    (value + alignment - 1) & ~(alignment - 1)
}

@inline(__always)
private func physicalPointer(
    _ address: UInt64
) -> UnsafeMutableRawPointer {
    UnsafeMutableRawPointer(bitPattern: UInt(address))!
}

@inline(__always)
private func loadUInt32(
    from base: UnsafeRawPointer,
    at offset: UInt64
) -> UInt32 {
    base.load(
        fromByteOffset: Int(offset),
        as: UInt32.self
    )
}

@inline(__always)
private func loadUInt64(
    from base: UnsafeRawPointer,
    at offset: UInt64
) -> UInt64 {
    base.load(
        fromByteOffset: Int(offset),
        as: UInt64.self
    )
}

private func copyBytes(
    from source: UnsafeRawPointer,
    sourceOffset: UInt64,
    to destinationAddress: UInt64,
    count: UInt64
) {
    let destination = physicalPointer(destinationAddress)
    var offset: UInt64 = 0

    // Copy aligned data eight bytes at a time.
    if (sourceOffset & 7) == 0 && (destinationAddress & 7) == 0 {
        while offset + 8 <= count {
            let word = source.load(
                fromByteOffset: Int(sourceOffset + offset),
                as: UInt64.self
            )

            destination.storeBytes(
                of: word,
                toByteOffset: Int(offset),
                as: UInt64.self
            )

            offset += 8
        }
    }
    // Copy a possible unaligned source, or the trailing bytes after the
    // word-sized loop, without making alignment assumptions.
    while offset < count {
        let byte = source.load(
            fromByteOffset: Int(sourceOffset + offset),
            as: UInt8.self
        )

        destination.storeBytes(
            of: byte,
            toByteOffset: Int(offset),
            as: UInt8.self
        )

        offset += 1
    }
}

private func zeroBytes(
    at address: UInt64,
    count: UInt64
) {
    let destination = physicalPointer(address)
    var offset: UInt64 = 0

    // Clear aligned memory efficiently in machine-word units.
    if (address & 7) == 0 {
        while offset + 8 <= count {
            destination.storeBytes(
                of: UInt64(0),
                toByteOffset: Int(offset),
                as: UInt64.self
            )

            offset += 8
        }
    }

    // Finish a possible unaligned region or sub-word tail.
    while offset < count {
        destination.storeBytes(
            of: UInt8(0),
            toByteOffset: Int(offset),
            as: UInt8.self
        )

        offset += 1
    }
}

private struct LoadedKernel {
    let entry: UInt64
    let virtualBase: UInt64
    let physicalBase: UInt64
    let physicalEnd: UInt64
}

private func loadKernel(
    image: UnsafeRawPointer,
    imageSize: UInt
) -> LoadedKernel {
    let size = UInt64(imageSize)

    // Validate the fixed Mach-O header before reading any of its fields.
    guard size >= machHeader64Size else {
        fail("Mach-O header is truncated")
    }

    // This loader only supports the little-endian, 64-bit, arm64 build for BCM2711.
    guard loadUInt32(from: image, at: 0) == machMagic64 else {
        fail("kernel is not a little-endian 64-bit Mach-O")
    }

    guard loadUInt32(from: image, at: 4) == cpuTypeARM64 else {
        fail("kernel is not arm64")
    }

    guard loadUInt32(from: image, at: 12) == machExecute else {
        fail("kernel is not an MH_EXECUTE image")
    }

    let commandCount = loadUInt32(from: image, at: 16)
    let commandBytes = UInt64(loadUInt32(from: image, at: 20))

    // A malformed command area must not allow reads past the embedded image.
    guard
        rangeFits(
            offset: machHeader64Size,
            length: commandBytes,
            total: size
        )
    else {
        fail("Mach-O load commands are truncated")
    }

    var imageVMBase: UInt64 = 0
    var entryVMAddress: UInt64 = 0
    var commandOffset = machHeader64Size

    // The first pass discovers the kernel's linked Mach header address and
    // initial PC which are needed before any segment can be placed.
    for _ in 0..<commandCount {
        guard
            rangeFits(
                offset: commandOffset,
                length: 8,
                total: size
            )
        else {
            fail("Mach-O load command header is truncated")
        }

        let command = loadUInt32(from: image, at: commandOffset)
        let commandSize = UInt64(
            loadUInt32(from: image, at: commandOffset + 4)
        )

        guard
            commandSize >= 8
                && rangeFits(
                    offset: commandOffset,
                    length: commandSize,
                    total: size
                )
        else {
            fail("Mach-O load command has an invalid size")
        }

        if command == loadSegment64 {
            // segment_command_64 contains the VM/file ranges used during load.
            guard commandSize >= segmentCommand64Size else {
                fail("LC_SEGMENT_64 is truncated")
            }

            let vmAddress = loadUInt64(
                from: image,
                at: commandOffset + 24
            )

            let fileOffset = loadUInt64(
                from: image,
                at: commandOffset + 40
            )

            let fileSize = loadUInt64(
                from: image,
                at: commandOffset + 48
            )

            if fileOffset == 0 && fileSize != 0 {
                guard imageVMBase == 0 || imageVMBase == vmAddress else {
                    fail("Mach-O has multiple file-offset-zero segments")
                }

                imageVMBase = vmAddress
            }
        } else if command == loadUnixThread {
            guard commandSize >= unixThreadMinimumSize else {
                fail("LC_UNIXTHREAD is truncated")
            }

            entryVMAddress = loadUInt64(
                from: image,
                at: commandOffset + unixThreadPCOffset
            )
        }

        commandOffset += commandSize
    }

    guard imageVMBase >= kernelHeaderOffset else {
        fail("could not determine the kernel virtual base")
    }

    // The entry point must be translatable as an offset from the image base.
    guard entryVMAddress >= imageVMBase else {
        fail("kernel entry precedes the Mach-O header")
    }

    let sourceAddress = UInt64(UInt(bitPattern: image))

    // The embedded source image must finish before the 32 MiB destination.
    // Otherwise copying a segment could overwrite unread source bytes.
    guard
        rangeFits(
            offset: sourceAddress,
            length: size,
            total: kernelPhysicalAddress
        )
    else {
        fail("loader and embedded kernel overlap the XNU destination")
    }

    var physicalEnd = kernelPhysicalAddress
    commandOffset = machHeader64Size

    // The second pass copies each segment now that imageVMBase is known.
    for _ in 0..<commandCount {
        let command = loadUInt32(from: image, at: commandOffset)
        let commandSize = UInt64(
            loadUInt32(from: image, at: commandOffset + 4)
        )

        if command == loadSegment64 {
            let vmAddress = loadUInt64(
                from: image,
                at: commandOffset + 24
            )

            let vmSize = loadUInt64(
                from: image,
                at: commandOffset + 32
            )

            let fileOffset = loadUInt64(
                from: image,
                at: commandOffset + 40
            )

            let fileSize = loadUInt64(
                from: image,
                at: commandOffset + 48
            )

            if vmSize != 0 {
                guard vmAddress >= imageVMBase else {
                    fail("nonempty segment precedes the kernel VM base")
                }

                guard fileSize <= vmSize else {
                    fail("segment file size exceeds its VM size")
                }

                guard
                    rangeFits(
                        offset: fileOffset,
                        length: fileSize,
                        total: size
                    )
                else {
                    fail("segment contents are outside the Mach-O")
                }

                let vmOffset = vmAddress - imageVMBase

                guard vmOffset <= physicalMemorySize - kernelPhysicalAddress
                else {
                    fail("segment destination overflows RAM")
                }

                let destination =
                    kernelPhysicalAddress + vmOffset

                guard
                    rangeFits(
                        offset: destination,
                        length: vmSize,
                        total: physicalMemorySize
                    )
                else {
                    fail("segment does not fit in RAM")
                }

                copyBytes(
                    from: image,
                    sourceOffset: fileOffset,
                    to: destination,
                    count: fileSize
                )

                zeroBytes(
                    at: destination + fileSize,
                    count: vmSize - fileSize
                )

                let segmentEnd = destination + vmSize

                if segmentEnd > physicalEnd {
                    physicalEnd = segmentEnd
                }
            }
        }

        commandOffset += commandSize
    }

    let entryOffset = entryVMAddress - imageVMBase

    guard entryOffset < physicalMemorySize - kernelPhysicalAddress
    else {
        fail("kernel entry does not fit in RAM")
    }

    return LoadedKernel(
        entry: kernelPhysicalAddress + entryOffset,
        virtualBase: imageVMBase - kernelHeaderOffset,
        physicalBase: kernelPhysicalBase,
        physicalEnd: physicalEnd
    )
}

// XNU does not consume the standard flattened device tree supplied by QEMU.
// It expects Apple's depth-first packed format:
//
//   DeviceTreeNode
//   DeviceTreeNodeProperty[]
//   property values padded to four bytes
//   child DeviceTreeNode subtrees
private struct AppleDeviceTreeWriter {
    private let base: UnsafeMutableRawPointer
    private(set) var offset: Int = 0

    init(address: UInt64) {
        // The caller reserves and bounds-checks one physical page for the tree.
        base = physicalPointer(address)
    }

    mutating private func writeByte(_ value: UInt8) {
        base.storeBytes(
            of: value,
            toByteOffset: offset,
            as: UInt8.self
        )

        offset += 1
    }

    mutating private func writeUInt32(_ value: UInt32) {
        base.storeBytes(
            of: value,
            toByteOffset: offset,
            as: UInt32.self
        )

        offset += 4
    }

    mutating private func writeUInt64(_ value: UInt64) {
        // Apple device-tree properties are padded to four bytes, so a
        // 64-bit value is not necessarily eight-byte aligned. Emit the
        // little-endian representation explicitly instead of making a typed
        // UInt64 store that can fault while EL2 alignment checking is active.
        var remaining = value

        for _ in 0..<8 {
            writeByte(UInt8(remaining & 0xff))
            remaining >>= 8
        }
    }

    mutating private func padPropertyValue() {
        while (offset & 3) != 0 {
            writeByte(0)
        }
    }

    mutating private func propertyHeader(
        _ name: StaticString,
        length: UInt32
    ) {
        let headerOffset = offset

        // DeviceTreeNodeProperty has a fixed 32-byte, NUL-padded name field.
        for _ in 0..<32 {
            writeByte(0)
        }

        // Ensure all property names below are compile-time literals shorter than the
        // 31-character maximum.
        for index in 0..<name.utf8CodeUnitCount {
            base.storeBytes(
                of: name.utf8Start[index],
                toByteOffset: headerOffset + index,
                as: UInt8.self
            )
        }

        writeUInt32(length)
    }

    mutating func node(
        properties: UInt32,
        children: UInt32
    ) {
        writeUInt32(properties)
        writeUInt32(children)
    }

    mutating func stringProperty(
        _ name: StaticString,
        _ value: StaticString
    ) {
        propertyHeader(
            name,
            length: UInt32(value.utf8CodeUnitCount + 1)
        )

        for index in 0..<value.utf8CodeUnitCount {
            writeByte(value.utf8Start[index])
        }

        writeByte(0)
        padPropertyValue()
    }

    mutating func uint32Property(
        _ name: StaticString,
        _ value: UInt32
    ) {
        propertyHeader(name, length: 4)
        writeUInt32(value)
    }

    mutating func uint64Property(
        _ name: StaticString,
        _ value: UInt64
    ) {
        propertyHeader(name, length: 8)
        writeUInt64(value)
    }

    mutating func uint64PairProperty(
        _ name: StaticString,
        _ first: UInt64,
        _ second: UInt64
    ) {
        propertyHeader(name, length: 16)
        writeUInt64(first)
        writeUInt64(second)
    }

    mutating func repeatedByteProperty(
        _ name: StaticString,
        byte: UInt8,
        count: Int
    ) {
        propertyHeader(name, length: UInt32(count))

        for _ in 0..<count {
            writeByte(byte)
        }

        padPropertyValue()
    }
}

private func buildAppleDeviceTree(
    at address: UInt64,
    counterFrequency: UInt32
) -> UInt64 {
    var tree = AppleDeviceTreeWriter(address: address)

    // device-tree
    // ├── chosen
    // ├── cpus
    // │   └── cpu0
    // ├── arm-io
    // │   └── uart0
    // └── defaults
    tree.node(properties: 1, children: 4)
    tree.stringProperty("name", "device-tree")

    tree.node(properties: 4, children: 1)
    tree.stringProperty("name", "chosen")
    tree.uint64Property("dram-base", kernelPhysicalBase)
    tree.uint64Property(
        "dram-size",
        physicalMemorySize - kernelPhysicalBase
    )

    // Bring-up-only deterministic seed. XNU requires 256 bytes before
    // early_random() can initialize.
    tree.repeatedByteProperty(
        "random-seed",
        byte: 0xa5,
        count: 256
    )

    // arm_vm_prot_init requires this node even when no optional TrustCache
    // range is supplied.
    tree.node(properties: 1, children: 0)
    tree.stringProperty("name", "memory-map")

    tree.node(properties: 1, children: 1)
    tree.stringProperty("name", "cpus")

    // We only care about CPU0 right now. The other QEMU CPUs remain in the
    // loader's holding loop until secondary-core startup is implemented.
    tree.node(properties: 9, children: 0)
    tree.stringProperty("name", "cpu0")

    // XNU recognizes the boot CPU by the literal state "running".
    tree.stringProperty("state", "running")

    // BCM2711 CPU 0 has MPIDR Aff0 equal to zero.
    tree.uint32Property("reg", 0)

    // Use CNTFRQ_EL0 rather than duplicating QEMU's architectural timer
    // frequency in the loader.
    tree.uint32Property("timebase-frequency", counterFrequency)

    // pe_identify_machine uses these values to populate XNU's clock ratios.
    tree.uint32Property("bus-frequency", 100_000_000)
    tree.uint32Property("memory-frequency", 400_000_000)
    tree.uint32Property("peripheral-frequency", 100_000_000)
    tree.uint32Property("fixed-frequency", counterFrequency)
    tree.uint32Property("clock-frequency", 1_500_000_000)

    tree.node(properties: 3, children: 1)
    tree.stringProperty("name", "arm-io")
    tree.stringProperty("device_type", "soc")

    // pe_arm_get_soc_base_phys() reads the second 64-bit ranges element as the
    // BCM2711 peripheral base.
    tree.uint64PairProperty(
        "ranges",
        0,
        0xfe000000
    )

    tree.node(properties: 4, children: 0)
    tree.stringProperty("name", "uart0")
    tree.stringProperty("compatible", "arm,pl011")
    tree.uint32Property("AAPL,phandle", 1)
    tree.uint64PairProperty(
        "reg",
        0x00201000,
        0x1000
    )

    tree.node(properties: 2, children: 0)
    tree.stringProperty("name", "defaults")
    tree.uint32Property("serial-device", 1)

    return UInt64(tree.offset)
}

// The compiler does things to the stores by combining them into wider stores
// and breaks things, I just want it to work first so compiler optimization
// begone!
@_optimize(none)
private func buildBootArgs(
    at address: UInt64,
    kernel: LoadedKernel,
    deviceTreeAddress: UInt64,
    deviceTreeLength: UInt64,
    topOfKernelData: UInt64
) {

    // Zero the entire ABI structure so video information, machineType,
    // bootFlags, padding, and unused command-line bytes have defined values.
    zeroBytes(at: address, count: bootArgsSize)

    let args = physicalPointer(address)

    args.storeBytes(
        of: UInt16(2),
        toByteOffset: 0,
        as: UInt16.self
    )

    args.storeBytes(
        of: UInt16(2),
        toByteOffset: 2,
        as: UInt16.self
    )

    args.storeBytes(
        of: kernel.virtualBase,
        toByteOffset: 8,
        as: UInt64.self
    )

    args.storeBytes(
        of: kernel.physicalBase,
        toByteOffset: 16,
        as: UInt64.self
    )

    args.storeBytes(
        of: physicalMemorySize - kernel.physicalBase,
        toByteOffset: 24,
        as: UInt64.self
    )

    args.storeBytes(
        of: topOfKernelData,
        toByteOffset: 32,
        as: UInt64.self
    )

    args.storeBytes(
        of: kernel.virtualBase
            + (deviceTreeAddress - kernel.physicalBase),
        toByteOffset: 96,
        as: UInt64.self
    )

    args.storeBytes(
        of: UInt32(deviceTreeLength),
        toByteOffset: 104,
        as: UInt32.self
    )

    let commandLine: StaticString = "debug=0xa serial=1"

    for index in 0..<commandLine.utf8CodeUnitCount {
        args.storeBytes(
            of: commandLine.utf8Start[index],
            toByteOffset: 108 + index,
            as: UInt8.self
        )
    }

    args.storeBytes(
        of: UInt8(0),
        toByteOffset: 108 + commandLine.utf8CodeUnitCount,
        as: UInt8.self
    )

    args.storeBytes(
        of: physicalMemorySize,
        toByteOffset: 1144,
        as: UInt64.self
    )
}

// Check whether an address points to a Flattened Device Tree header.
private func hasFDTMagic(_ address: UnsafeRawPointer?) -> Bool {

    guard let address else {
        return false
    }

    // Interpret the beginning of the DTB as individual bytes.
    let bytes = address.assumingMemoryBound(to: UInt8.self)

    // Every FDT starts with the big-endian magic value 0xd00dfeed.
    return bytes[0] == 0xd0 && bytes[1] == 0x0d && bytes[2] == 0xfe && bytes[3] == 0xed
}

// Export this function under the unmangled C symbol "loader_main" so the
// AArch64 startup assembly can invoke it with `bl loader_main`.
//
// Under the AArch64 boot convention used here, x0 contains the DTB address.
// The C calling convention maps x0 to this function's first argument.
@_cdecl("loader_main")
public func loaderMain(
    _ qemuFDT: UnsafeRawPointer?,
    _ kernelImage: UnsafeRawPointer,
    _ kernelImageSize: UInt,
    _ counterFrequency: UInt64
) {
    write("XNU loader entered at EL2.\n")

    if hasFDTMagic(qemuFDT) {
        write("QEMU supplied a valid Linux FDT.\n")
    } else {
        write("QEMU did not supply a valid Linux FDT.\n")
    }

    guard counterFrequency != 0 && counterFrequency <= UInt64(UInt32.max)
    else {
        fail("CNTFRQ_EL0 is outside the XNU device-tree range")
    }

    write("Loading XNU Mach-O segments.\n")

    let kernel = loadKernel(
        image: kernelImage,
        imageSize: kernelImageSize
    )

    let deviceTreeAddress = alignUp(
        kernel.physicalEnd,
        to: kernelPageSize
    )

    guard
        rangeFits(
            offset: deviceTreeAddress,
            length: appleDeviceTreeMaximumSize,
            total: physicalMemorySize
        )
    else {
        fail("no room for the Apple device tree")
    }

    let deviceTreeLength = buildAppleDeviceTree(
        at: deviceTreeAddress,
        counterFrequency: UInt32(counterFrequency)
    )

    guard deviceTreeLength <= appleDeviceTreeMaximumSize else {
        fail("Apple device tree exceeded its reserved page")
    }

    let bootArgsAddress = alignUp(
        deviceTreeAddress + deviceTreeLength,
        to: kernelPageSize
    )

    let topOfKernelData = alignUp(
        bootArgsAddress + bootArgsSize,
        to: kernelPageSize
    )

    guard topOfKernelData <= physicalMemorySize else {
        fail("boot metadata does not fit in RAM")
    }

    buildBootArgs(
        at: bootArgsAddress,
        kernel: kernel,
        deviceTreeAddress: deviceTreeAddress,
        deviceTreeLength: deviceTreeLength,
        topOfKernelData: topOfKernelData
    )

    write("Entering XNU at EL1.\n")

    enterXNU(
        UInt(kernel.entry),
        UInt(bootArgsAddress)
    )
}
