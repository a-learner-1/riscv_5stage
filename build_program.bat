@echo off
setlocal
set CROSS=riscv-none-elf-

if not exist build mkdir build

%CROSS%gcc -march=rv32i -mabi=ilp32 -O2 -ffreestanding -fno-builtin ^
  -fno-stack-protector -fno-pic -msmall-data-limit=0 -mno-relax ^
  -ffunction-sections -fdata-sections -Wall -Wextra ^
  -nostdlib -nostartfiles -static -Wl,-T,software/link.ld ^
  -Wl,-Map,build/c_demo.map -Wl,--gc-sections -Wl,--no-relax ^
  software/start.S software/main.c -o build/c_demo.elf
if errorlevel 1 exit /b 1

%CROSS%objcopy -O binary -j .text build/c_demo.elf build/c_demo_text.bin
if errorlevel 1 exit /b 1

%CROSS%objcopy -O binary -j .data build/c_demo.elf build/c_demo_data.bin
if errorlevel 1 exit /b 1

%CROSS%objdump -d -S build/c_demo.elf > build/c_demo.dump
python tools/bin_to_hex.py build/c_demo_text.bin programs/c_demo.hex
if errorlevel 1 exit /b 1
python tools/bin_to_hex.py build/c_demo_data.bin programs/c_demo_data.hex
if errorlevel 1 exit /b 1

echo Built programs/c_demo.hex and programs/c_demo_data.hex successfully.
endlocal
