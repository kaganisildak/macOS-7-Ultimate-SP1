# Win7Mac Command Prompt shell support, sourced by the startup files in this directory.
# install.sh copies them to ~/Library/Application Support/Win7Mac/cmd-zsh/ and the "Win7 Command Prompt" Terminal
# profile starts zsh with ZDOTDIR pointing there. The user's own startup files are sourced unchanged, from their
# usual place, in zsh's usual order; nothing in $HOME is edited.
#
# Each startup file here runs:   w7_cmd_enter .zshrc && source "$REPLY"; w7_cmd_leave
# The user's file is sourced at top level, not inside a function, so its typeset/local/setopt work as usual.

# This directory, and the user's own startup-file directory ($HOME, or the ZDOTDIR their ~/.zshenv sets).
typeset -g W7_CMD_ZDOTDIR=${W7_CMD_ZDOTDIR:-$ZDOTDIR}
typeset -g W7_USER_ZDOTDIR=${W7_USER_ZDOTDIR:-$HOME}

# w7_cmd_enter <file>: ZDOTDIR becomes the user's directory, as their files expect. Succeeds, with the path in
# REPLY, when <user dir>/<file> is readable.
w7_cmd_enter() {
    ZDOTDIR=$W7_USER_ZDOTDIR
    REPLY=$W7_USER_ZDOTDIR/$1
    [[ -r $REPLY ]]
}

# w7_cmd_leave: remembers where the user's files live now (~/.zshenv may set ZDOTDIR=~/.config/zsh), and points
# ZDOTDIR back here so zsh reads its next startup file from this directory.
w7_cmd_leave() {
    W7_USER_ZDOTDIR=${ZDOTDIR:-$HOME}
    ZDOTDIR=$W7_CMD_ZDOTDIR
}

# After the last startup file, ZDOTDIR is the user's again, so nested shells and ~/.zlogout behave as usual.
w7_cmd_finish() {
    if [[ $W7_USER_ZDOTDIR == "$HOME" ]]; then
        unset ZDOTDIR
    else
        export ZDOTDIR=$W7_USER_ZDOTDIR
    fi
}

# /etc/zshrc puts the history in ${ZDOTDIR:-$HOME}/.zsh_history, which is this directory, and Terminal's
# /etc/zshrc_Apple_Terminal copies that path into SHELL_SESSION_HISTFILE_SHARED (where per-session history is
# merged on exit). Both go back to the user's file.
w7_cmd_fix_history() {
    local ours=$W7_CMD_ZDOTDIR/.zsh_history theirs=$W7_USER_ZDOTDIR/.zsh_history
    [[ $HISTFILE == "$ours" ]] && HISTFILE=$theirs
    [[ $SHELL_SESSION_HISTFILE_SHARED == "$ours" ]] && SHELL_SESSION_HISTFILE_SHARED=$theirs
    return 0
}

# w7_cmd_prompt [dir]: prints the Command Prompt prompt for dir (default $PWD): /Users/me/src -> C:\Users\me\src>
w7_cmd_prompt() {
    local dir=${1:-$PWD}
    print -r -- "C:${dir//\//\\}>"
}

_w7_cmd_precmd() {
    local dir=${PWD//\//\\}
    PS1="C:${dir//\%/%%}>"
    RPS1=
}

# Runs after the user's ~/.zshrc, so this prompt wins over theirs; the hook is added last, after any prompt
# theme's own precmd hook. Prompt expansion is limited to %-escapes, so a folder name is never executed.
w7_cmd_prompt_setup() {
    setopt prompt_percent no_prompt_subst no_prompt_bang
    autoload -Uz add-zsh-hook
    add-zsh-hook -d precmd _w7_cmd_precmd
    add-zsh-hook precmd _w7_cmd_precmd
    _w7_cmd_precmd
}
