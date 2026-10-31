#!/usr/bin/env bash
set -euo pipefail

# Build dependencies for the JUCE desktop app on Ubuntu 24.04.
# Keep this list in sync with docs/build-and-setup.md.
sudo apt-get update
sudo apt-get install -y \
  build-essential cmake pkg-config git zip unzip \
  libasound2-dev libjack-jackd2-dev \
  libfreetype-dev libfontconfig1-dev \
  libx11-dev libxext-dev libxrender-dev libxrandr-dev \
  libxinerama-dev libxcursor-dev libxcomposite-dev \
  libxi-dev libxtst-dev \
  libglu1-mesa-dev mesa-common-dev \
  libcurl4-openssl-dev libssl-dev libflac-dev libvorbis-dev \
  libiw-dev
