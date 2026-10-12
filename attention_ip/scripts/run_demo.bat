@echo off
rem ================================================================
rem  Attention RTL IP - on-site demo script (Windows cmd)
rem  Use when reviewer gives a NEW input:
rem    1) edit Q/K/V at top of scripts\demo_vector.py and save
rem    2) double-click THIS file
rem  Steps: 1) demo_vector.py writes 1 vector + prints cheat sheet
rem         2) vvp runs it (no recompile) -> ALL PASS + new waveform
rem  ASCII only on purpose (avoids GBK garbled text)
rem  Restore standard 44 vectors afterwards: run_sim.bat
rem ================================================================
cd /d "%~dp0.."

echo === [1/2] Build 1 demo vector (see cheat sheet below) ===
python scripts\demo_vector.py %1
if errorlevel 1 goto :err

echo.
echo === [2/2] Run simulation (vvp, no compile) ===
cd sim
vvp attention_ip.tb.vvp
cd ..
echo.
echo Done. New waveform: sim\attention_ip.vcd  (Reload GTKWave)
echo To restore 44 vectors: run scripts\run_sim.bat
echo.
pause
exit /b 0

:err
echo DEMO FAILED
pause
exit /b 1
