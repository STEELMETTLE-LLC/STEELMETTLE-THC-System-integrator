# STEELMETTLE THC Systems Integrator

## Install

1. Download **STEELMETTLE-THC-Systems-Integrator-Installer.exe**
2. Run it - the installer sets up everything automatically
3. Click **Launch App** when done, or use the Desktop / Start Menu shortcut

## Updates
The app checks for new installer releases and newer commits on the main branch.
When a release is available, you will be prompted to install it. New commits without
a release are reported with a link to the GitHub changes page.

Firmware update checks download public, precompiled release assets; no GitHub
account or token is required. The customer installer includes compiled firmware
binaries only. Firmware source repositories remain private.

Forge flashing uses the Nucleo ST-LINK through OpenOCD; STM32CubeProgrammer is
not required. If RDP1 is enabled, clearing it triggers a full flash erase,
including saved presets and calibration. The app warns before erasing, then
reinstalls the released firmware, applies the selected AI settings, verifies
them, and re-enables RDP1. Keep the controller powered and connected until the
operation completes.

Forge firmware releases must include runtime AI-settings support. Customer
packages include released firmware binaries only; firmware source remains
private, although binaries can still be reverse-engineered.

Core flashing downloads the Arduino CLI and required board support
automatically on first use.

---
*(c) STEELMETTLE LLC - All rights reserved.*
