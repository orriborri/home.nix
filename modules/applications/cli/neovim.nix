{ pkgs, ... }:

{
  enable = true;
  vimdiffAlias = true;
  viAlias = true;
  vimAlias = true;

  plugins = with pkgs.vimPlugins; [
    base16-vim
    vim-markdown
    vim-gitgutter
    vim-surround
    editorconfig-vim
    ctrlp-vim
  ];
  extraConfig = ''
    " Sync clipboard with Wayland
    set clipboard=unnamedplus

    let g:clipboard = {
        \   'name': 'wl-clipboard',
        \   'copy': {
        \      '+': 'wl-copy',
        \      '*': 'wl-copy --primary',
        \    },
        \   'paste': {
        \      '+': 'wl-paste --no-newline',
        \      '*': 'wl-paste --no-newline --primary',
        \   },
        \ }

    " Restore cursor position
    function! ResCur()
        if line("'\"") <= line("$")
            normal! g`"
            return 1
        endif
    endfunction
    augroup resCur
        autocmd!
        autocmd BufWinEnter * call ResCur()
    augroup END

    " Don't move the cursor after pasting
    " (by jumping to back start of previously changed text)
    noremap p p`[
    noremap P P`[

    " GitGutter hunk navigation (Nordic keyboard friendly)
    nmap <leader>j <Plug>(GitGutterNextHunk)
    nmap <leader>k <Plug>(GitGutterPrevHunk)

    " Auto-save when leaving insert mode or losing focus
    autocmd InsertLeave,FocusLost * silent! wall

    " Python: 2-space indentation + retab on save
    autocmd FileType python setlocal tabstop=2 shiftwidth=2 softtabstop=2 expandtab
    autocmd BufWritePre *.py retab

    " Keep 500 lines of command line history
    set history=500

    " Write persistent undo files
    set undofile
    set undodir=$HOME/.config/nvim/undo
    set undolevels=1000
    set undoreload=1000
  '';
}
