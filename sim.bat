@echo off
setlocal enabledelayedexpansion
rem ============================================================
rem  Run a Vivado XSim simulation from the command line.
rem
rem  Usage:   sim.bat <TP folder> <testbench module> [gui]
rem  Example: sim.bat TP2 tb_uart_loopback
rem           sim.bat TP1 tb_ALU gui
rem
rem  Compiles every .v in <TP>\src and <TP>\sim, elaborates the
rem  testbench module, runs it, and fails if the log contains
rem  "TEST FAILED" or a $fatal.
rem ============================================================

rem --- EDIT THIS to match your Vivado install ---
set VIVADO_BIN=C:\Xilinx\2025.1\Vivado\bin

if "%~2"=="" (
  echo Usage: sim.bat ^<TP folder^> ^<testbench module^> [gui]
  exit /b 2
)
if not exist "%VIVADO_BIN%\xvlog.bat" (
  echo ERROR: Vivado not found at %VIVADO_BIN% - edit VIVADO_BIN in sim.bat
  exit /b 2
)

set ROOT=%~dp0
set TP=%~1
set TB=%~2
set BUILD=%ROOT%build\%TP%\%TB%

if not exist "%ROOT%%TP%\src" (
  echo ERROR: "%TP%\src" not found
  exit /b 2
)

if not exist "%BUILD%" mkdir "%BUILD%"
pushd "%BUILD%"

set SRCS=
for %%f in ("%ROOT%%TP%\src\*.v" "%ROOT%%TP%\sim\*.v") do set SRCS=!SRCS! "%%~ff"

echo === Compiling %TP% ===
call "%VIVADO_BIN%\xvlog.bat" !SRCS! || goto fail

echo === Elaborating %TB% ===
call "%VIVADO_BIN%\xelab.bat" %TB% -debug typical -s %TB%_sim || goto fail

if /i "%~3"=="gui" (
  echo === Opening waveform GUI ===
  call "%VIVADO_BIN%\xsim.bat" %TB%_sim -gui
  popd
  exit /b 0
)

echo === Running %TB% ===
call "%VIVADO_BIN%\xsim.bat" %TB%_sim -R -log sim.log || goto fail
findstr /c:"TEST FAILED" /c:"Fatal:" sim.log >nul && goto fail

popd
echo === SIM OK ===
exit /b 0

:fail
popd
echo === SIM FAILED ===
exit /b 1
