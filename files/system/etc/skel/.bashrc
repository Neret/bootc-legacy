[ -f /etc/bashrc ] && . /etc/bashrc

if command -v micro >/dev/null 2>&1; then
    export EDITOR=micro
else
    export EDITOR=nano
fi
export VISUAL="$EDITOR"

if command -v podman >/dev/null 2>&1 && [ -n "$XDG_RUNTIME_DIR" ]; then
    export DOCKER_HOST="unix://$XDG_RUNTIME_DIR/podman/podman.sock"
fi
export OLLAMA_API_BASE='http://127.0.0.1:11434'

[[ $- != *i* ]] && return

HISTSIZE=50000
HISTFILESIZE=50000
HISTCONTROL=ignoreboth:erasedups
shopt -s histappend checkwinsize autocd cdspell

command -v sudo >/dev/null 2>&1 && alias sudo='sudo '

if command -v eza >/dev/null 2>&1; then
    alias ls='eza --group-directories-first'
    alias ll='eza -l --git --group-directories-first'
    alias la='eza -la --git --group-directories-first'
    alias lt='eza --tree --level=2'
    alias l1='eza -1'

    l.() {
        local -a entries
        shopt -s nullglob
        entries=( .[!.]* ..?* )
        shopt -u nullglob
        (( ${#entries[@]} )) || return 0
        eza -d -- "${entries[@]}"
    }
fi

if command -v bat >/dev/null 2>&1; then
    alias c='bat --style=plain --paging=never'
    alias cata='bat'
fi

if command -v ug >/dev/null 2>&1; then
    alias uge='ug -E'
    alias ugf='ug -F'
    alias ugz='ug -z'
    alias ugze='ug -zE'
    alias ugzf='ug -zF'
fi

if ! command -v fd >/dev/null 2>&1 && command -v fdfind >/dev/null 2>&1; then
    alias fd='fdfind'
fi

command -v rg >/dev/null 2>&1 && alias rgh='rg --smart-case --hidden --glob "!.git"'
command -v xdg-open >/dev/null 2>&1 && alias open='xdg-open >/dev/null'

if command -v dircolors >/dev/null 2>&1 && [ -r "$HOME/.dircolors" ]; then
    eval "$(dircolors -b "$HOME/.dircolors")"
fi

apue() {
    if (( $# != 1 )); then
        echo 'uso: apue <file.c>' >&2
        return 2
    fi

    local src="$1"
    local out="${src%.c}"

    gcc -ansi \
        -I"$HOME/Progetti/apue.3e/include" \
        -Wall \
        -DLINUX \
        -D_GNU_SOURCE \
        "$src" \
        -o "$out" \
        -L"$HOME/Progetti/apue.3e/lib" \
        -lapue \
        -pthread
}

# Cache dell'output degli init: rigenerata solo se il binario e' piu' recente
_cache_init() {
    local name=$1 bin cache
    bin=$(type -P "$2") || return 0
    cache="${XDG_CACHE_HOME:-$HOME/.cache}/shell-init/$name.bash"
    if [[ ! -s $cache || $bin -nt $cache ]]; then
        mkdir -p "${cache%/*}" &&
            "${@:2}" >"$cache.tmp" 2>/dev/null &&
            mv -f "$cache.tmp" "$cache"
    fi
    [[ -s $cache ]] && . "$cache"
}

_cache_init zoxide zoxide init bash
_cache_init fzf fzf --bash
unset -f _cache_init

# Prompt leggero: cartella, branch git, freccia verde/rossa
for _gp in /usr/share/git-core/contrib/completion/git-prompt.sh \
           /usr/share/doc/git/contrib/completion/git-prompt.sh; do
    [ -r "$_gp" ] && { . "$_gp"; break; }
done
unset _gp

__prompt() {
    local e=$? c=32 g=
    (( e )) && c=31
    declare -F __git_ps1 >/dev/null && g=$(__git_ps1 ' (%s)')
    PS1="\[\e[1;34m\]\w\[\e[0m\]\[\e[33m\]${g}\[\e[0m\] \[\e[1;${c}m\]❯\[\e[0m\] "
}
PROMPT_COMMAND=__prompt
