@echo off
rem Pre-build step for TP3 simulations, called by sim.bat from the build dir.
rem   %1 = build directory (absolute), %2 = testbench name
rem Copies static test data (sim\data) and generates test vectors with
rem Python into the build directory, where $readmemh looks for files.
copy /y "%~dp0data\*.hex" "%~1" >nul || exit /b 1
python "%~dp0..\py\gen_vectors.py" "%~1" || exit /b 1
exit /b 0
