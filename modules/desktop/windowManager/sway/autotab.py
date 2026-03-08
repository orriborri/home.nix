#!/usr/bin/env python3
"""Master-stack: first window is master (left), rest are tabbed (right)."""
import i3ipc


def find_tabbed(ws):
    for node in ws.nodes:
        if node.layout == 'tabbed':
            return node
    return None


def is_descendant(window, container):
    parent = window.parent
    while parent:
        if parent.id == container.id:
            return True
        parent = parent.parent
    return False


def on_new(i3, event):
    tree = i3.get_tree()
    focused = tree.find_focused()
    if not focused:
        return
    ws = focused.workspace()
    leaves = ws.leaves()

    if len(leaves) < 3:
        return

    tabbed = find_tabbed(ws)

    if tabbed:
        # Tabbed container exists — move new window into it if it landed outside
        if not is_descendant(focused, tabbed):
            target = tabbed.leaves()[0]
            i3.command(f'[con_id={target.id}] mark --add _tab')
            i3.command('move container to mark _tab')
            i3.command(f'[con_id={target.id}] unmark _tab')
    else:
        # No tabbed container yet — create master + tabbed structure
        master = leaves[0]
        second = leaves[1]
        i3.command(f'[con_id={second.id}] focus')
        i3.command('splitv')
        i3.command('layout tabbed')
        i3.command(f'[con_id={second.id}] mark --add _tab')
        for leaf in leaves[2:]:
            i3.command(f'[con_id={leaf.id}] focus')
            i3.command('move container to mark _tab')
        i3.command(f'[con_id={second.id}] unmark _tab')
        i3.command(f'[con_id={focused.id}] focus')


ipc = i3ipc.Connection()
ipc.on('window::new', on_new)
ipc.main()
