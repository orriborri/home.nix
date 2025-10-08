#!/bin/bash
current=$(cpupower frequency-info -p | grep 'governor' | grep -o 'performance\|powersave')
if [ "$current" = "performance" ]; then
    sudo cpupower frequency-set -g powersave
else
    sudo cpupower frequency-set -g performance
fi