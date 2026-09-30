@echo off
setlocal
cd /d "%~dp0"
set "UART_CROSS=riscv-none-elf-"

where riscv-none-elf-gcc.exe >nul 2>nul
if errorlevel 1 (
  set "UART_CROSS=D:\Tools\xpack-riscv-none-elf-gcc-15.2.0-1-win32-x64\xpack-riscv-none-elf-gcc-15.2.0-1\bin\riscv-none-elf-"
)
if not "%UART_CROSS%"=="riscv-none-elf-" if not exist "%UART_CROSS%gcc.exe" (
  echo ERROR: RISC-V GCC was not found. Add it to PATH or edit UART_CROSS.
  exit /b 1
)
if not exist build mkdir build
if not exist programs mkdir programs

"%UART_CROSS%gcc" -march=rv32i -mabi=ilp32 -O2 -ffreestanding -fno-builtin ^
  -fno-stack-protector -fno-pic -msmall-data-limit=0 -mno-relax ^
  -ffunction-sections -fdata-sections -Wall -Wextra ^
  -nostdlib -nostartfiles -static -Wl,-T,software/link.ld ^
  -Wl,-Map,build/uart_demo.map -Wl,--gc-sections -Wl,--no-relax ^
  software/start.S software/uart_demo.c -lgcc -o build/uart_demo.elf
if errorlevel 1 exit /b 1

"%UART_CROSS%objcopy" -O binary -j .text build/uart_demo.elf build/uart_demo_text.bin
if errorlevel 1 exit /b 1
"%UART_CROSS%objcopy" -O binary -j .data build/uart_demo.elf build/uart_demo_data.bin
if errorlevel 1 exit /b 1
"%UART_CROSS%objdump" -d -S build/uart_demo.elf > build/uart_demo.dump
if errorlevel 1 exit /b 1

python tools/bin_to_hex.py build/uart_demo_text.bin programs/uart_demo.hex
if errorlevel 1 exit /b 1
python tools/bin_to_hex.py build/uart_demo_data.bin programs/uart_demo_data.hex
if errorlevel 1 exit /b 1
echo Built UART demo successfully.
exit /b 0
