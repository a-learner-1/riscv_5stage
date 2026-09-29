@echo off
setlocal
set CROSS=riscv-none-elf-

where %CROSS%gcc.exe >nul 2>nul
if errorlevel 1 (
  set TOOLCHAIN_BIN=D:\Tools\xpack-riscv-none-elf-gcc-15.2.0-1-win32-x64\xpack-riscv-none-elf-gcc-15.2.0-1\bin
  if exist "D:\Tools\xpack-riscv-none-elf-gcc-15.2.0-1-win32-x64\xpack-riscv-none-elf-gcc-15.2.0-1\bin\riscv-none-elf-gcc.exe" (
    set CROSS=D:\Tools\xpack-riscv-none-elf-gcc-15.2.0-1-win32-x64\xpack-riscv-none-elf-gcc-15.2.0-1\bin\riscv-none-elf-
  ) else (
    echo ERROR: riscv-none-elf-gcc was not found in PATH or D:\Tools.
    exit /b 1
  )
)

if not exist build mkdir build
if not exist programs mkdir programs

%CROSS%gcc -march=rv32i -mabi=ilp32 -O2 -ffreestanding -fno-builtin ^
  -fno-stack-protector -fno-pic -msmall-data-limit=0 -mno-relax ^
  -ffunction-sections -fdata-sections -Wall -Wextra -Wno-maybe-uninitialized ^
  -DITERATIONS=1 -DPERFORMANCE_RUN=1 ^
  -Ibenchmarks/coremark -Isoftware/coremark_port -Isoftware ^
  -nostdlib -nostartfiles -static -Wl,-T,software/link.ld ^
  -Wl,-Map,build/coremark.map -Wl,--gc-sections -Wl,--no-relax ^
  software/coremark_port/start_coremark.S ^
  software/coremark_port/core_portme.c ^
  benchmarks/coremark/core_list_join.c ^
  benchmarks/coremark/core_main.c ^
  benchmarks/coremark/core_matrix.c ^
  benchmarks/coremark/core_state.c ^
  benchmarks/coremark/core_util.c ^
  -lgcc -o build/coremark.elf
if errorlevel 1 exit /b 1

%CROSS%objcopy -O binary -j .text build/coremark.elf build/coremark_text.bin
if errorlevel 1 exit /b 1

%CROSS%objcopy -O binary -j .data build/coremark.elf build/coremark_data.bin
if errorlevel 1 exit /b 1

%CROSS%objdump -d -S build/coremark.elf > build/coremark.dump
%CROSS%size build/coremark.elf

python tools/bin_to_hex.py build/coremark_text.bin programs/coremark.hex
if errorlevel 1 exit /b 1
python tools/bin_to_hex.py build/coremark_data.bin programs/coremark_data.hex
if errorlevel 1 exit /b 1

echo Built CoreMark smoke-test images successfully.
echo NOTE: ITERATIONS=1 is for functional validation, not an official score.
endlocal
