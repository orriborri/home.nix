#!/usr/bin/env python3
# swaysome - i3-like workspace behavior for sway with output-specific numbering

import i3ipc
import sys

sway = i3ipc.Connection()

# Output to workspace range mapping
OUTPUT_RANGES = {
    'eDP-1': 10,      # Left screen: 11, 12, 13...
    'HDMI-A-1': 20,   # Mid screen: 21, 22, 23...
    'DP-1': 30        # Right screen: 31, 32, 33...
}

def get_focused_output():
    return [o for o in sway.get_outputs() if o.focused][0]

def get_workspace_number(key_num):
    """Convert key number (1-9) to output-specific workspace number"""
    output = get_focused_output()
    base = OUTPUT_RANGES.get(output.name, 10)  # Default to 10s if unknown output
    return base + key_num

def focus_workspace(key_num):
    workspace_num = get_workspace_number(key_num)
    sway.command(f'workspace number {workspace_num}')

def move_to_workspace(key_num):
    workspace_num = get_workspace_number(key_num)
    sway.command(f'move container to workspace number {workspace_num}')

if __name__ == '__main__':
    if len(sys.argv) < 3:
        print("Usage: swaysome.py [focus|move] <key_num>")
        sys.exit(1)
    
    action = sys.argv[1]
    key_num = int(sys.argv[2])
    
    if action == 'focus':
        focus_workspace(key_num)
    elif action == 'move':
        move_to_workspace(key_num)
