@echo off
rem cdchime neural voice daemon. Optional: cdchime works without it, it just stays quiet.
rem Needs Python 3 with the edge-tts package:  pip install edge-tts
setlocal
set "PY="
for %%P in (pythonw.exe python.exe) do if not defined PY for /f "delims=" %%I in ('where %%P 2^>nul') do if not defined PY set "PY=%%I"
if not defined PY (
    echo Python 3 was not found. Install it from python.org, then:  pip install edge-tts
    pause
    exit /b 1
)
"%PY%" -c "import edge_tts" 2>nul || (
    echo The edge-tts package is missing. Run:  pip install edge-tts
    pause
    exit /b 1
)
start "" "%PY%" "%~dp0tts_daemon.py"
