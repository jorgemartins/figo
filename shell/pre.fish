# Figo shell integration for fish, first half. Loaded first from ~/.config/fish/conf.d.
#
# Replaces this shell with Figo's pty wrapper, which starts the real shell inside a
# pseudo-terminal so that Figo can follow what is being typed. See pre.zsh for the reasoning
# behind each condition.

# Fig put ~/.local/bin on the PATH for every shell, and startup files written since may count
# on it being there. It is also where the `figo` command is linked.
if test -d "$HOME/.local/bin"; and not contains -- "$HOME/.local/bin" $PATH
    set -gx PATH $PATH "$HOME/.local/bin"
end

if status is-interactive
    and isatty stdin
    and isatty stdout
    and not set -q FIGO_DISABLED
    and not set -q FIGO_HELPER
    and test "$TERM" != dumb
    and test "$TERM_PROGRAM" != WarpTerminal
    and not set -q INSIDE_EMACS
    and not set -q CI
    and not set -q SSH_CONNECTION
    and not set -q SSH_CLIENT
    and not set -q SSH_TTY
    and begin
        not set -q FIGO_TERM
        or begin
            set -q TMUX
            and not set -q FIGO_TERM_TMUX
        end
    end

    set -l figo_wrapper "$HOME/Library/Application Support/figo/bin/fish (figoterm)"
    set -q FIGO_TERM_PATH
    and set figo_wrapper $FIGO_TERM_PATH

    if test -x "$figo_wrapper"
        set -l figo_login 0
        status is-login
        and set figo_login 1
        set -x FIGO_SHELL (status fish-path)
        set -x FIGO_IS_LOGIN_SHELL $figo_login
        exec "$figo_wrapper"
    end
end
