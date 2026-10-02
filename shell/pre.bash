# Figo shell integration for bash, first half. Sourced at the very top of ~/.bashrc (and of the
# login profile).
#
# Replaces this shell with Figo's pty wrapper, which starts the real shell inside a
# pseudo-terminal so that Figo can follow what is being typed. See pre.zsh for the reasoning
# behind each condition.

# Fig put ~/.local/bin on the PATH for every shell, and startup files written since may count
# on it being there. It is also where the `figo` command is linked.
if [[ -d "${HOME}/.local/bin" && ":${PATH}:" != *":${HOME}/.local/bin:"* ]]; then
  PATH="${PATH:+"${PATH}:"}${HOME}/.local/bin"
fi

if [[ $- == *i* && -t 0 && -t 1
      && -z "${FIGO_DISABLED-}" && -z "${FIGO_HELPER-}"
      && -z "${BASH_EXECUTION_STRING-}"
      && "${TERM-}" != dumb
      && "${TERM_PROGRAM-}" != WarpTerminal
      && -z "${INSIDE_EMACS-}" && -z "${CI-}"
      && -z "${SSH_CONNECTION-}${SSH_CLIENT-}${SSH_TTY-}" ]] \
   && { [[ -z "${FIGO_TERM-}" ]] || [[ -n "${TMUX-}" && -z "${FIGO_TERM_TMUX-}" ]]; }
then
  _figo_wrapper="${FIGO_TERM_PATH:-$HOME/Library/Application Support/figo/bin/bash (figoterm)}"
  if [[ -x "$_figo_wrapper" ]]; then
    _figo_login=0
    shopt -q login_shell && _figo_login=1
    # $BASH is not always bash: a login shell started by name rather than by path reports the
    # account's default shell there, which on a Mac is usually zsh. Ask the system instead.
    _figo_shell="$BASH"
    if [[ "${_figo_shell##*/}" != bash* ]]; then
      _figo_shell="$(ps -p $$ -o comm= 2>/dev/null)"
      [[ "$_figo_shell" == /* && -x "$_figo_shell" ]] || _figo_shell="$(type -P bash)"
    fi
    FIGO_SHELL="$_figo_shell" FIGO_IS_LOGIN_SHELL="$_figo_login" exec "$_figo_wrapper"
  fi
  unset _figo_wrapper
fi
