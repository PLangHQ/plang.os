@echo off
rem Runs a .goal file with this folder's plang, in the goal's own folder (plang runs the app it is in).
rem Used by the .goal file association that start.ps1 registers.
cd /d "%~dp1"
"%~dp0runtime\plang.exe" "%~n1"
echo.
pause
