# STEELMETTLE THC Systems Integrator

## Install

1. Download **STEELMETTLE-THC-Systems-Integrator-Installer.exe**
2. Run it - the installer sets up everything automatically
3. Click **Launch App** when done, or use the Desktop / Start Menu shortcut

## Updates
The app checks for new installer releases and newer commits on the main branch.
When a release is available, you will be prompted to install it. New commits without
a release are reported with a link to the GitHub changes page.

Private firmware checks use binary-only release repositories, not the source
repositories. Create a fine-grained token with **Contents: Read-only** access
only to **THC-AUTOSET-Firmware-Releases** and
**STEELMETTLE-THC-Forge-Firmware-Releases**. Set the
**STEELMETTLE_GITHUB_TOKEN** environment variable or save the token in
**secrets/github.token** under the install folder. Do not share or commit it;
programs running as your Windows account can access its environment variables.

---
*(c) STEELMETTLE LLC - All rights reserved.*
