@echo off
setlocal
cd /d "%~dp0"
if not defined GPIO_CROSS set "GPIO_CROSS=riscv-none-elf-"
where "%GPIO_CROSS%gcc.exe" >nul 2>nul
if errorlevel 1 (
  if "%GPIO_CROSS%"=="riscv-none-elf-" set "GPIO_CROSS=D:\Tools\xpack-riscv-none-elf-gcc-15.2.0-1-win32-x64\xpack-riscv-none-elf-gcc-15.2.0-1\bin\riscv-none-elf-"
)
"%GPIO_CROSS%gcc" --version >nul 2>nul
if errorlevel 1 (
  echo ERROR: RISC-V GCC not found. Add it to PATH or set GPIO_CROSS.
  exit /b 1
)
if not exist build mkdir build
if not exist programs mkdir programs
"%GPIO_CROSS%gcc" -march=rv32i -mabi=ilp32 -O2 -ffreestanding -fno-builtin ^
  -fno-stack-protector -fno-pic -msmall-data-limit=0 -mno-relax ^
  -ffunction-sections -fdata-sections -Wall -Wextra ^
  -nostdlib -nostartfiles -static -Wl,-T,software/link.ld ^
  -Wl,-Map,build/gpio_test.map -Wl,--gc-sections -Wl,--no-relax ^
  software/start.S software/gpio_test.c -lgcc -o build/gpio_test.elf
if errorlevel 1 exit /b 1
"%GPIO_CROSS%objcopy" -O binary -j .text build/gpio_test.elf build/gpio_test_text.bin
if errorlevel 1 exit /b 1
"%GPIO_CROSS%objcopy" -O binary -j .data build/gpio_test.elf build/gpio_test_data.bin
if errorlevel 1 exit /b 1
"%GPIO_CROSS%objdump" -d -S build/gpio_test.elf > build/gpio_test.dump
if errorlevel 1 exit /b 1
python tools/bin_to_hex.py build/gpio_test_text.bin programs/gpio_test.hex
if errorlevel 1 exit /b 1
python tools/bin_to_hex.py build/gpio_test_data.bin programs/gpio_test_data.hex
if errorlevel 1 exit /b 1
echo Built GPIO self-test successfully.
exit /b 0
