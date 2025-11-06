#!/usr/bin/env python3
# swaysome - i3-like workspace behavior for sway
# Source: https://gitlab.com/hyask/swaysome

import i3ipc
import sys

sway = i3ipc.Connection()

def get_focused_output():
    return [o for o in sway.get_outputs() if o.focused][0]

def get_workspaces_on_output(output):
    return [w for w in sway.get_workspaces() if w.output == output.name]

def focus_workspace(num):
    output = get_focused_output()
    workspaces = get_workspaces_on_output(output)
    
    # Find workspace with this number on current output
    for ws in workspaces:
        if ws.num == num:
            sway.command(f'workspace number {num}')
            return
    
    # Create new workspace on current output
    sway.command(f'workspace number {num}')

def move_to_workspace(num):
    sway.command(f'move container to workspace number {num}')

if __name__ == '__main__':
    if len(sys.argv) < 3:
        print("Usage: swaysome.py [focus|move] <workspace_num>")
        sys.exit(1)
    
    action = sys.argv[1]
    num = int(sys.argv[2])
    
    if action == 'focus':
        focus_workspace(num)
    elif action == 'move':
        move_to_workspace(num)
