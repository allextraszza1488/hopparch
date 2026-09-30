#!/bin/bash
# Cheatsheet (SUPER+SHIFT+/): built each time it opens, so it can't go stale.
#   Hyprland: every bind that has a description (hyprctl binds)
#   nvim:     every keymap with a desc
#   fish:     the aliases
#   commands: ~/.config/hopparch/commands.list
# Type to filter; picking a line does nothing.

hyprland() {
  # modmask bits: SHIFT 1, CTRL 4, ALT 8, SUPER 64
  hyprctl binds -j | jq -r '
    def has($b): (. / $b | floor) % 2 == 1;
    def keyname: if . == "mouse:272" then "left drag" elif . == "mouse:273" then "right drag" else . end;
    .[] | select(.description != "")
    | [ (.modmask | [ (if has(64) then "SUPER" else empty end), (if has(4) then "CTRL" else empty end),
                      (if has(8) then "ALT" else empty end), (if has(1) then "SHIFT" else empty end) ]),
        (.key | keyname) ] as [$m, $k]
    | [($m + [$k] | join("+")), .description] | @tsv' |
    awk -F'\t' '!seen[$0]++ { printf "%-28s %s\n", $1, $2 }'
}

nvim_keys() {
  # nvim loads the user's config, then prints its keymaps that have a desc (sid -8 = nvim's own defaults, left out)
  timeout 5 nvim --headless '+lua for _, mode in ipairs({ "n", "v", "i", "t" }) do
      for _, m in ipairs(vim.api.nvim_get_keymap(mode)) do
        if m.desc and m.sid ~= -8 then io.stdout:write(string.format("%-28s %s\n", mode .. "  " .. vim.fn.keytrans(m.lhs), m.desc)) end
      end
    end' +qa 2>/dev/null
}

fish_keys() {
  printf '%-28s %s\n' 'Ctrl+R' 'search the history' 'Ctrl+T' 'pick a file'
  # "alias name 'command'" -> "name    command"
  fish -ic alias 2>/dev/null | sed -E "s/^alias ([^ ]+) '?(.*[^'])'?$/\1\t\2/" |
    awk -F'\t' 'NF == 2 { printf "%-28s %s\n", $1, $2 }'
}

commands() {
  grep -v -e '^#' -e '^[[:space:]]*$' ~/.config/hopparch/commands.list
}

section() { printf '== %s ==\n' "$1"; "$2"; }

{
  section Hyprland hyprland
  section nvim nvim_keys
  section fish fish_keys
  section commands commands
} | fuzzel --dmenu --prompt 'keys> ' --width 70 --lines 20 >/dev/null || true
