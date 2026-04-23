# Shell Configuration

## Vi Mode

Zsh uses vi keybindings. Type `help` for a quick reference.

### Key bindings
- `jj` — enter normal mode from insert
- `i` — insert mode
- `v` — visual mode
- `/` — search
- `Ctrl-R` — history search backward
- `Ctrl-S` — history search forward

### Navigation
- `0` / `$` — line start/end
- `w` / `b` — word forward/back
- `f<c>` — jump to char

### Editing
- `dd` — delete line
- `cc` — change line
- `yy` — yank line
- `p` — paste
- `u` — undo

## Multiline Commands

- Incomplete commands (unclosed `{`, `(`, pipes) show a `∙` continuation prompt
- Bracketed paste is enabled — pasting multiline text won't trigger vi keybindings
- `INTERACTIVE_COMMENTS` is enabled — use `#` for inline comments

## Notifications

Mako notification daemon runs as a systemd user service. Desktop notifications work out of the box.
