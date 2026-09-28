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

%CROSS%objcopy -O binary build/c_demo.elf build/c_demo.bin
if errorlevel 1 exit /b 1

%CROSS%objdump -d -S build/c_demo.elf > build/c_demo.dump
python tools/bin_to_hex.py build/c_demo.bin programs/c_demo.hex
if errorlevel 1 exit /b 1

echo Built programs/c_demo.hex successfully.
endlocal
