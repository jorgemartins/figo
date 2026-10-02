# Figo shell integration for zsh, first half. Sourced at the very top of ~/.zshrc.
#
# Replaces this shell with Figo's pty wrapper, which starts the real shell inside a
# pseudo-terminal so that Figo can follow what is being typed. Everything below the line that
# sources this file runs in that inner shell.
#
# The wrapper is only started for an interactive shell attached to a terminal that is not
# already wrapped. Anything unusual (no terminal, a remote session, an editor's embedded shell,
# a missing binary) leaves the shell exactly as it was.

# Fig put ~/.local/bin on the PATH for every shell, and startup files written since may count
# on it being there. It is also where the `figo` command is linked.
if [[ -d "${HOME}/.local/bin" && ":${PATH}:" != *":${HOME}/.local/bin:"* ]]; then
  PATH="${PATH:+"${PATH}:"}${HOME}/.local/bin"
fi

if [[ -o interactive && -t 0 && -t 1
      && -z "${FIGO_DISABLED-}" && -z "${FIGO_HELPER-}"
      && -z "${ZSH_EXECUTION_STRING-}"
      && "${TERM-}" != dumb
      && "${TERM_PROGRAM-}" != WarpTerminal
      && -z "${INSIDE_EMACS-}" && -z "${CI-}"
      && -z "${SSH_CONNECTION-}${SSH_CLIENT-}${SSH_TTY-}" ]] \
   && { [[ -z "${FIGO_TERM-}" ]] || [[ -n "${TMUX-}" && -z "${FIGO_TERM_TMUX-}" ]] }
then
  _figo_wrapper="${FIGO_TERM_PATH:-$HOME/Library/Application Support/figo/bin/zsh (figoterm)}"
  if [[ -x "$_figo_wrapper" ]]; then
    # zsh does not know the path it was started from. The login shell is right in practice.
    if [[ "${SHELL:t}" == zsh && -x "$SHELL" ]]; then
      _figo_shell="$SHELL"
    else
      _figo_shell="${commands[zsh]:-/bin/zsh}"
    fi
    _figo_login=0
    [[ -o login ]] && _figo_login=1
    FIGO_SHELL="$_figo_shell" FIGO_IS_LOGIN_SHELL="$_figo_login" exec "$_figo_wrapper"
  fi
  unset _figo_wrapper
fi
