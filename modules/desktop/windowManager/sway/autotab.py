#!/usr/bin/env python3
"""Master-stack: first window is master (left), rest are tabbed (right)."""
import i3ipc


def walk(node):
    yield node
    for child in node.nodes + node.floating_nodes:
        yield from walk(child)


def find_marked(node, mark):
    for candidate in walk(node):
        if mark in candidate.marks:
            return candidate
    return None


def is_descendant(window, container):
    parent = window.parent
    while parent:
        if parent.id == container.id:
            return True
        parent = parent.parent
    return False


def on_new(i3, event):
    window = event.container
    if not window:
        return
    if window.floating in ('auto_on', 'user_on'):
        return
    ws = window.workspace()
    if not ws:
        return
    leaves = [leaf for leaf in ws.leaves() if leaf.floating == 'user_off']

    if len(leaves) <= 1:
        return

    master_mark = f'_autotab_master_{ws.id}'
    stack_mark = f'_autotab_stack_{ws.id}'
    tree = i3.get_tree()

    master = find_marked(tree, master_mark)
    if not master or not master.workspace() or master.workspace().id != ws.id:
        master = leaves[0]
        i3.command(f'[con_id={master.id}] mark --add {master_mark}')

    stack = find_marked(tree, stack_mark)
    if not stack or not stack.workspace() or stack.workspace().id != ws.id:
        seed = next((leaf for leaf in leaves if leaf.id != master.id), None)
        if not seed:
            return
        i3.command(f'[con_id={seed.id}] focus')
        i3.command('split vertical')
        i3.command('focus parent')
        i3.command('layout tabbed')
        i3.command(f'mark --add {stack_mark}')

    # Keep workspace in two primary panes: left master and right stack.
    i3.command(f'[con_id={master.id}] focus')
    i3.command('split horizontal')

    tree = i3.get_tree()
    ws = tree.find_by_id(ws.id)
    master = find_marked(tree, master_mark)
    stack = find_marked(tree, stack_mark)
    if not ws or not master or not stack:
        return

    target = stack.leaves()[0] if stack.leaves() else None
    if not target:
        return
    move_mark = f'_autotab_move_{ws.id}'
    i3.command(f'[con_id={target.id}] mark --add {move_mark}')

    # Enforce: master stays alone on left, every other tiled leaf goes right into tabs.
    for leaf in [leaf for leaf in ws.leaves() if leaf.floating == 'user_off']:
        if leaf.id == master.id:
            continue
        if is_descendant(leaf, stack):
            continue
        i3.command(f'[con_id={leaf.id}] move container to mark {move_mark}')

    i3.command(f'[con_id={target.id}] unmark {move_mark}')
    i3.command(f'[con_id={window.id}] focus')


ipc = i3ipc.Connection()
ipc.on('window::new', on_new)
ipc.main()
