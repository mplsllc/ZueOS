#!/bin/bash
# Launches Calamares as root. Uses `sudo -E` (preserving the caller's
# environment — DISPLAY/XAUTHORITY — so the GUI actually works) rather than
# pkexec/polkit, since the live user already has passwordless sudo and a
# separate polkit auth prompt would just be redundant friction.
exec sudo -E calamares
