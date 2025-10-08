#!/bin/bash
echo "Setting up passwordless cpupower access..."
echo "orre ALL=(ALL) NOPASSWD: /nix/store/*/bin/cpupower frequency-set -g performance" | sudo tee /etc/sudoers.d/cpupower
echo "orre ALL=(ALL) NOPASSWD: /nix/store/*/bin/cpupower frequency-set -g powersave" | sudo tee -a /etc/sudoers.d/cpupower
echo "Done! Run this script manually to enable passwordless CPU governor switching."