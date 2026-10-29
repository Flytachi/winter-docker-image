# Tab completion for `./call` and `call` in bash — read by every interactive bash in the
# image (Alpine's /etc/bash/bashrc sources /etc/bash/*.sh).
#
# A copy of winter-kernel's console/Template/Build/completion_bash, which `call cfg
# completion -i` installs on a developer's machine. That cannot work in a container: the
# user has no home, and a container is recreated from the image anyway. The script only
# finds the project's `call` and asks it (`call complete`), so the suggestions always come
# from the winter-kernel the project has.
#
# bash looks a completion up by the command word and, for a path like `./call`, by what
# follows the last slash too: `./call` and `call` both match. `php call` does not.

_php_winter_call_find() {
    local dir="$PWD"
    while [ "$dir" != "/" ]; do
        [ -f "$dir/call" ] && { echo "$dir/call"; return 0; }
        dir="$(dirname "$dir")"
    done
    return 1
}

_php_winter_call() {
    local script completions words
    script=$(_php_winter_call_find) || return
    local IFS=$'\n'
    completions=$(COMP_LINE="$COMP_LINE" COMP_POINT="$COMP_POINT" \
        php "$script" complete 2>/dev/null)
    # Strip descriptions (name:description → name)
    words=$(echo "$completions" | sed 's/:.*$//')
    COMPREPLY=($(compgen -W "$words" -- "${COMP_WORDS[$COMP_CWORD]}"))
    return 0
}
complete -o default -F _php_winter_call call
