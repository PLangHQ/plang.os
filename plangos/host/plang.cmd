@echo off
rem Runs this folder's host plang (runtime\plang.exe) in this folder, so it runs Start.goal.
"%~dp0runtime\plang.exe" %*
