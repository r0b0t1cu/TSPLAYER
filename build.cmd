@echo off
setlocal

REM Requires TASM 3.x / TASM32 on PATH.
tasm -t80 -g3 -fFF -dWBW TSPLAYER.ASM TSPLAYER.COM TSPLAYER.LST
exit /b %ERRORLEVEL%
