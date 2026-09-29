CROSS   ?= riscv-none-elf-
CC       = $(CROSS)gcc
OBJCOPY  = $(CROSS)objcopy
OBJDUMP  = $(CROSS)objdump
PYTHON  ?= python

CFLAGS  = -march=rv32i -mabi=ilp32 -O2 -ffreestanding -fno-builtin \
          -fno-stack-protector -fno-pic -msmall-data-limit=0 -mno-relax \
          -ffunction-sections -fdata-sections -Wall -Wextra
LDFLAGS = -nostdlib -nostartfiles -static -Wl,-T,software/link.ld \
          -Wl,-Map,build/c_demo.map -Wl,--gc-sections -Wl,--no-relax

.PHONY: all clean
all: programs/c_demo.hex programs/c_demo_data.hex build/c_demo.dump

build/c_demo.elf: software/start.S software/main.c software/link.ld
	mkdir -p build
	$(CC) $(CFLAGS) $(LDFLAGS) software/start.S software/main.c -o $@

build/c_demo_text.bin: build/c_demo.elf
	$(OBJCOPY) -O binary -j .text $< $@

build/c_demo_data.bin: build/c_demo.elf
	$(OBJCOPY) -O binary -j .data $< $@

programs/c_demo.hex: build/c_demo_text.bin tools/bin_to_hex.py
	$(PYTHON) tools/bin_to_hex.py $< $@

programs/c_demo_data.hex: build/c_demo_data.bin tools/bin_to_hex.py
	$(PYTHON) tools/bin_to_hex.py $< $@

build/c_demo.dump: build/c_demo.elf
	$(OBJDUMP) -d -S $< > $@

clean:
	rm -rf build programs/c_demo.hex programs/c_demo_data.hex
