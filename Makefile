BUILD := build
BOOT_BIN := $(BUILD)/boot.bin
STAGE2_BIN := $(BUILD)/stage2.bin
KERNEL_BIN := $(BUILD)/kernel.bin
HELLO_BIN := $(BUILD)/hello.bin
DISK_IMG := $(BUILD)/eva.img

.PHONY: all run run-headless clean

all: $(DISK_IMG)

$(BUILD):
	mkdir -p $(BUILD)

$(BOOT_BIN): boot/boot.asm | $(BUILD)
	nasm -f bin boot/boot.asm -o $(BOOT_BIN)

$(STAGE2_BIN): boot/stage2.asm | $(BUILD)
	nasm -f bin boot/stage2.asm -o $(STAGE2_BIN)

$(KERNEL_BIN): kernel/kernel.asm | $(BUILD)
	nasm -f bin kernel/kernel.asm -o $(KERNEL_BIN)

$(HELLO_BIN): apps/hello.asm | $(BUILD)
	nasm -f bin apps/hello.asm -o $(HELLO_BIN)

$(DISK_IMG): $(BOOT_BIN) $(STAGE2_BIN) $(KERNEL_BIN) $(HELLO_BIN)
	dd if=/dev/zero of=$(DISK_IMG) bs=512 count=2880
	dd if=$(BOOT_BIN) of=$(DISK_IMG) conv=notrunc
	dd if=$(STAGE2_BIN) of=$(DISK_IMG) bs=512 seek=1 conv=notrunc
	dd if=$(KERNEL_BIN) of=$(DISK_IMG) bs=512 seek=17 conv=notrunc
	dd if=$(HELLO_BIN) of=$(DISK_IMG) bs=512 seek=280 conv=notrunc

run: $(DISK_IMG)
	qemu-system-x86_64 -drive format=raw,file=$(DISK_IMG)

run-headless: $(DISK_IMG)
	qemu-system-x86_64 -drive format=raw,file=$(DISK_IMG) -display none -serial file:$(BUILD)/serial.log -no-reboot
	cat $(BUILD)/serial.log

clean:
	rm -rf $(BUILD)
