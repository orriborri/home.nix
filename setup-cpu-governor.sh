#!/bin/bash

# Script to set up passwordless CPU governor switching
echo "Setting up CPU governor permissions..."

# Create sudoers rule
sudo tee /etc/sudoers.d/cpu-governor << 'EOF'
orre ALL=(ALL) NOPASSWD: /bin/sh -c echo powersave \| tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
orre ALL=(ALL) NOPASSWD: /bin/sh -c echo performance \| tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
EOF

echo "Done! You can now change CPU governors without password."