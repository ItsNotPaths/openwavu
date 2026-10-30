#!/usr/bin/env bash
# Removes or restores the // comments of a game module (modules/<game>/*.c, .h, .odin).
# modules/<game>/COMMENTS keeps, per file, the hash after removal and every comment:
#   path:LINE > <text>   text after the code on that line (spacing kept)
#   path:LINE = <text>   a whole comment line
# Swiss marks (a comment starting with `(hole`, up to the line where the form closes) are never removed.
# Restore only touches files whose hash still matches; the rest stay listed in COMMENTS.
set -euo pipefail
cd "$(dirname "$0")"

strip_awk='
BEGIN { apostrophe = sprintf("%c", 39) }
function comment_start(s,    i, c, quote) {
    quote = ""
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (quote != "") {
            if (c == "\\" && quote != "`") i++
            else if (c == quote) quote = ""
        } else if (c == "\"" || c == apostrophe || c == "`") quote = c
        else if (c == "/" && substr(s, i + 1, 1) == "/") return i
    }
    return 0
}
function form_depth(s, depth,    i, c) {
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "(") depth++
        else if (c == ")" && --depth == 0) return 0
    }
    return depth
}
{
    at = comment_start($0)
    if (!at) { mark_depth = 0; print; next }
    code = substr($0, 1, at - 1)
    text = substr($0, at + 2)
    if (mark_depth > 0 && code ~ /^[ \t]*$/) { mark_depth = form_depth(text, mark_depth); print; next }
    if (tolower(text) ~ /^[ \t]*\([ \t]*hole[ \t)]/) { mark_depth = form_depth(text, 0); print; next }
    mark_depth = 0
    if (code ~ /^[ \t]*$/) { print FILENAME ":" FNR " = " $0 > entries; next }
    sub(/[ \t]+$/, "", code)
    print FILENAME ":" FNR " > " substr($0, length(code) + 1) > entries
    print code
}'

restore_awk='
FNR == NR {
    split($1, place, ":"); line = place[2] + 0
    text = $0; sub(/^[^ ]+ [>=] /, "", text)
    kind[line] = $2; saved[line] = text
    next
}
{ stripped[++count] = $0 }
END {
    taken = 0
    for (line = 1; taken < count || (line in kind); line++) {
        if ((line in kind) && kind[line] == "=") { print saved[line]; continue }
        out = stripped[++taken]
        if ((line in kind) && kind[line] == ">") out = out saved[line]
        print out
    }
}'

hash() { sha256sum "$1" | cut -d' ' -f1; }

remove() {
    local game=$1 list=modules/$1/COMMENTS file entries
    [ -e "$list" ] && { echo "$list exists: restore first" >&2; return 1; }
    entries=$(mktemp)
    : > "$list"
    while IFS= read -r file; do
        : > "$entries"
        awk -v entries="$entries" "$strip_awk" "$file" > "$file.strip"
        if [ -s "$entries" ]; then
            mv "$file.strip" "$file"
            echo "$file sha256 $(hash "$file")" >> "$list"
            cat "$entries" >> "$list"
        else
            rm "$file.strip"
        fi
    done < <(find "modules/$game" -type f \( -name '*.c' -o -name '*.h' -o -name '*.odin' \) | sort)
    rm "$entries"
    echo "removed comments from $(grep -c ' sha256 ' "$list") files -> $list"
}

restore() {
    local list=modules/$1/COMMENTS kept restored=0 file want entries
    [ -e "$list" ] || { echo "no $list" >&2; return 1; }
    kept=$(mktemp); entries=$(mktemp)
    while read -r file _ want; do
        awk -v f="$file" 'index($0, f ":") == 1 && $2 ~ /^[>=]$/' "$list" > "$entries"
        if [ -f "$file" ] && [ "$(hash "$file")" = "$want" ]; then
            awk "$restore_awk" "$entries" "$file" > "$file.restore" && mv "$file.restore" "$file"
            restored=$((restored + 1))
        else
            echo "changed since removal, kept in COMMENTS: $file"
            echo "$file sha256 $want" >> "$kept"
            cat "$entries" >> "$kept"
        fi
    done < <(grep ' sha256 ' "$list")
    rm "$entries"
    if [ -s "$kept" ]; then mv "$kept" "$list"; else rm "$kept" "$list"; fi
    echo "restored comments in $restored files"
}

# Up/down (or k/j) moves, Enter picks, q quits. Sets `choice`.
choose() {
    local title=$1 selected=0 key i
    shift
    local options=("$@")
    printf '%s\n' "$title" > /dev/tty
    while true; do
        for i in "${!options[@]}"; do
            if [ "$i" -eq "$selected" ]; then printf '\e[7m> %s\e[0m\e[K\n' "${options[i]}"
            else printf '  %s\e[K\n' "${options[i]}"; fi
        done > /dev/tty
        IFS= read -rsn1 key < /dev/tty
        if [ "$key" = $'\e' ]; then read -rsn2 -t 0.1 key < /dev/tty || key=; fi
        case $key in
            '[A' | k) [ "$selected" -gt 0 ] && selected=$((selected - 1)) ;;
            '[B' | j) [ "$selected" -lt $((${#options[@]} - 1)) ] && selected=$((selected + 1)) ;;
            '') break ;;
            q) exit 0 ;;
        esac
        printf '\e[%dA' "${#options[@]}" > /dev/tty
    done
    choice=${options[selected]}
}

trap 'tput cnorm > /dev/tty' EXIT
tput civis > /dev/tty
mapfile -t games < <(find modules -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
choose "game:" "${games[@]}"; game=$choice
choose "action:" remove restore; action=$choice
tput cnorm > /dev/tty
"$action" "$game"
