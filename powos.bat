@echo off
REM PowOS Launcher for Windows

echo.
echo     ____                 ____  _____
echo    / __ \____ _      __/ __ \/ ___/
echo   / /_/ / __ \ ^| /^| / / / / /\__ \
echo  / ____/ /_/ / ^|/ ^|/ / /_/ /___/ /
echo /_/    \____/^|__/^|__/\____//____/
echo.

REM Detect NVIDIA GPU
echo Detecting GPU...
where nvidia-smi >nul 2>&1
if %ERRORLEVEL% EQU 0 (
    set POWOS_GPU=nvidia
    set POWOS_IMAGE=ghcr.io/bazzite-org/bazzite-nvidia:stable
    echo Detected: NVIDIA
) else (
    set POWOS_GPU=mesa
    set POWOS_IMAGE=ghcr.io/bazzite-org/bazzite:stable
    echo Detected: Mesa (AMD/Intel)
)

echo Starting PowOS with %POWOS_GPU% image...
docker compose up --build %*
