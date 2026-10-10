@echo off
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\src\wrm.ps1" %*
