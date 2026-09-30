# hopparch fish config
set -g fish_greeting ""
fish_add_path ~/.local/bin

if status is-interactive
    # ls with icons, directories first
    alias ls 'eza --group-directories-first --icons'
    alias ll 'eza -l --group-directories-first --icons'
    alias la 'eza -la --group-directories-first --icons'
    # cat with syntax colors (glow is still there for .md)
    alias cat 'bat --paging=never'
    # cd remembers folders: `cd proj` jumps to ~/Proj from anywhere
    zoxide init fish --cmd cd | source
    # Ctrl+R: searchable history, Ctrl+T: pick a file
    fzf --fish | source
end
