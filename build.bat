@echo off
setlocal
rem ============================================================
rem  Run a non-project Vivado build (synth, place, route,
rem  reports, bitstream) from the command line.
rem
rem  Usage:   build.bat <TP folder> [name value ...]
rem  Example: build.bat TP3
rem           build.bat TP3 MMCM_OUT_DIV 10
rem
rem  Runs <TP>\scripts\build.tcl in batch mode; the name value
rem  pairs are passed to it (TP3: top-level parameter overrides).
rem  Output (reports, checkpoints, .bit, vivado.log) goes to
rem  build\<TP>\vivado.
rem ============================================================

rem --- EDIT THIS to match your Vivado install ---
set VIVADO_BIN=C:\Xilinx\2025.1\Vivado\bin

if "%~1"=="" (
  echo Usage: build.bat ^<TP folder^>
  exit /b 2
)
if not exist "%VIVADO_BIN%\vivado.bat" (
  echo ERROR: Vivado not found at %VIVADO_BIN% - edit VIVADO_BIN in build.bat
  exit /b 2
)

set ROOT=%~dp0
set TP=%~1
set SCRIPT=%ROOT%%TP%\scripts\build.tcl
set BUILD=%ROOT%build\%TP%\vivado

set EXTRA=
:args
shift
if "%~1"=="" goto args_done
set EXTRA=%EXTRA% %1
goto args
:args_done

if not exist "%SCRIPT%" (
  echo ERROR: "%TP%\scripts\build.tcl" not found
  exit /b 2
)

if not exist "%BUILD%" mkdir "%BUILD%"
pushd "%BUILD%"

echo === Building %TP% ===
call "%VIVADO_BIN%\vivado.bat" -mode batch -notrace -source "%SCRIPT%" -log vivado.log -journal vivado.jou -tclargs%EXTRA% || goto fail

popd
echo === BUILD OK ===
exit /b 0

:fail
popd
echo === BUILD FAILED ===
exit /b 1
