SWIFTC ?= swiftc
CLANG ?= clang
LLD ?= ld.lld
OBJCOPY ?= llvm-objcopy
QEMU ?= qemu-system-aarch64

BUILD_DIR := build
DTB := firmware/bcm2711-rpi-4-b.dtb
ELF := $(BUILD_DIR)/loader.elf
IMAGE := $(BUILD_DIR)/loader.img

SWIFTFLAGS := \
	-target aarch64-none-none-elf \
	-target-cpu cortex-a72 \
	-enable-experimental-feature Embedded \
	-no-allocations \
	-whole-module-optimization \
	-Osize \
	-parse-as-library \
	-Xfrontend -disable-stack-protector \
	-Xfrontend -function-sections

CLANGFLAGS := \
	--target=aarch64-none-elf \
	-mcpu=cortex-a72 \
	-ffreestanding \
	-fno-stack-protector

LDFLAGS := \
	-T linker.ld \
	--gc-sections \
	--build-id=none \
	-static	

.PHONY: all run verify-dtb

all: $(IMAGE)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(BUILD_DIR)/Loader.o: Loader.swift | $(BUILD_DIR)
	$(SWIFTC) $< $(SWIFTFLAGS) \
		-module-cache-path $(BUILD_DIR)/module-cache \
		-c -o $@

$(BUILD_DIR)/start.o: start.S | $(BUILD_DIR)
	$(CLANG) $(CLANGFLAGS) \
		-c $< -o $@

$(ELF): $(BUILD_DIR)/start.o $(BUILD_DIR)/Loader.o linker.ld
	$(LLD) $(LDFLAGS) \
		$(BUILD_DIR)/start.o $(BUILD_DIR)/Loader.o \
		-o $@

$(IMAGE): $(ELF)
	$(OBJCOPY) --output-target=binary $< $@

verify-dtb: $(DTB)
	@echo "75761b73c284e26623e4d1624bff13e67bce2ae620880efd81d6571a3739fcfb  $(DTB)" \
		| shasum -a 256 -c -

run: $(IMAGE) verify-dtb
	$(QEMU) \
		-M raspi4b \
		-kernel $(IMAGE) \
		-dtb $(DTB) \
		-display none \
		-serial stdio \
		-monitor none