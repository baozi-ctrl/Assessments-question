@echo off
rem ================================================================
rem  Attention RTL IP simulation script (Windows cmd)
rem  Usage: run from anywhere -> it cd's to project root automatically
rem  Steps: 1) generate test vectors  2) iverilog compile  3) vvp run
rem  Note: all text is ASCII on purpose (avoids GBK/UTF-8 garbled text)
rem ================================================================
cd /d "%~dp0.."

echo === [1/3] Generate test vectors ===
python scripts\gen_vectors.py
if errorlevel 1 goto :err

echo === [2/3] Compile (iverilog) ===
iverilog -g2012 -o sim\attention_ip.tb.vvp rtl\attention_ip.v tb\tb_attention_ip.v
if errorlevel 1 goto :err

echo === [3/3] Run ===
cd sim
vvp attention_ip.tb.vvp
cd ..
echo Done. Waveform: sim\attention_ip.vcd
echo.
pause
exit /b 0

:err
echo COMPILE/RUN FAILED
pause
exit /b 1
