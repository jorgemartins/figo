# Figo shell integration for zsh, second half. Sourced at the very bottom of ~/.zshrc.
#
# Tells the pty wrapper what the shell is doing through private escape sequences of the form
#   ESC ] 6977 ; <session id> ; <payload> BEL
# The wrapper removes them from the output, so the terminal never sees them.
#
# Only active inside the wrapper (FIGO_SESSION_ID is set) and never in helper shells that Figo
# itself starts to compute suggestions.

if [[ -o interactive && -n "${FIGO_SESSION_ID-}" && -z "${FIGO_HELPER-}" && -z "${_figo_loaded-}" ]]; then
  _figo_loaded=1

  # Write straight to the terminal: stdout may be redirected, and line-editor hooks run with
  # output going wherever the editor left it. The braces keep the error redirection local;
  # written on the exec itself it would send the shell's own stderr to /dev/null for good.
  if ! { exec {_figo_fd}>/dev/tty } 2>/dev/null; then
    unset _figo_fd _figo_loaded
    return 0
  fi

  typeset -g _figo_prefix=$'\e]6977;'"${FIGO_SESSION_ID};"
  typeset -g _figo_start="${_figo_prefix}StartPrompt"$'\a'
  typeset -g _figo_end="${_figo_prefix}EndPrompt"$'\a'
  typeset -g _figo_newcmd="${_figo_prefix}NewCmd"$'\a'
  typeset -g _figo_last_env="" _figo_last_aliases="" _figo_last_buffer=""

  if [[ "${SHELL:t}" == zsh && -x "$SHELL" ]]; then
    typeset -g _figo_shell_path="$SHELL"
  else
    typeset -g _figo_shell_path="${commands[zsh]:-/bin/zsh}"
  fi

  # Makes a value safe to put inside an escape sequence. Result in REPLY.
  _figo_escape() {
    REPLY=${1//\\/\\\\}
    REPLY=${REPLY//$'\e'/\\e}
    REPLY=${REPLY//$'\a'/\\a}
    REPLY=${REPLY//$'\n'/\\n}
    REPLY=${REPLY//$'\r'/\\r}
    REPLY=${REPLY//$'\t'/\\t}
  }

  _figo_wrap_prompts() {
    # Markers around the prompt tell the wrapper which cells are prompt and, with NewCmd, where
    # the command line begins. %{ %} tells zsh they take up no room. Themes rebuild the prompt
    # before every command line, so wrap whatever is there now unless it is already wrapped.
    [[ "$PS1" == "%{${_figo_start}%}"* ]] || PS1="%{${_figo_start}%}${PS1}%{${_figo_end}${_figo_newcmd}%}"
    [[ "$PS2" == "%{${_figo_start}%}"* ]] || PS2="%{${_figo_start}%}${PS2}%{${_figo_end}%}"
    if [[ -n "${RPS1-}" && "$RPS1" != "%{${_figo_start}%}"* ]]; then
      RPS1="%{${_figo_start}%}${RPS1}%{${_figo_end}%}"
    fi
  }

  _figo_unwrap_prompts() {
    # Give the prompts back while a command runs so nothing that reads or extends them sees
    # the markers.
    PS1=${${PS1#"%{${_figo_start}%}"}%"%{${_figo_end}${_figo_newcmd}%}"}
    PS2=${${PS2#"%{${_figo_start}%}"}%"%{${_figo_end}%}"}
    [[ -n "${RPS1-}" ]] && RPS1=${${RPS1#"%{${_figo_start}%}"}%"%{${_figo_end}%}"}
  }

  _figo_precmd() {
    local figo_status=$?
    local out="${_figo_prefix}PreCmd"$'\a'"${_figo_prefix}ExitCode=${figo_status}"$'\a'
    local name line REPLY

    _figo_escape "$PWD"
    out+="${_figo_prefix}Dir=${REPLY}"$'\a'
    out+="${_figo_prefix}Shell=zsh"$'\a'
    _figo_escape "$_figo_shell_path"
    out+="${_figo_prefix}ShellPath=${REPLY}"$'\a'
    out+="${_figo_prefix}PID=$$"$'\a'
    out+="${_figo_prefix}TTY=${TTY}"$'\a'
    _figo_escape "${USER:-root}"
    out+="${_figo_prefix}User=${REPLY}"$'\a'
    if [[ -n "${ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE-}" ]]; then
      out+="${_figo_prefix}ZshAutosuggestionColor=${ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE}"$'\a'
    elif (( ${+functions[_zsh_autosuggest_start]} )); then
      out+="${_figo_prefix}ZshAutosuggestionColor=fg=8"$'\a'
    fi

    # The exported environment and the aliases, so suggestions are computed with what this
    # shell would actually run. Built without starting a process, sent only when changed.
    local snapshot=""
    for name in ${(ok)parameters[(R)*export*]}; do
      _figo_escape "${(P)name}"
      snapshot+="${_figo_prefix}Var=${name}=${REPLY}"$'\a'
    done
    if [[ "$snapshot" != "$_figo_last_env" ]]; then
      _figo_last_env="$snapshot"
      out+="${_figo_prefix}EnvStart"$'\a'"${snapshot}${_figo_prefix}EnvEnd"$'\a'
    fi

    snapshot=""
    for name in ${(ok)aliases}; do
      snapshot+="${name}=${(q-)aliases[$name]}"$'\n'
    done
    if [[ "$snapshot" != "$_figo_last_aliases" ]]; then
      _figo_last_aliases="$snapshot"
      _figo_escape "$snapshot"
      out+="${_figo_prefix}Aliases=${REPLY}"$'\a'
    fi

    builtin print -rn -u $_figo_fd -- "$out"
    _figo_last_buffer=""

    # Other hooks may have been added since; ours has to see the final prompt.
    if [[ "${precmd_functions[-1]}" != _figo_precmd ]]; then
      precmd_functions=(${precmd_functions:#_figo_precmd} _figo_precmd)
    fi
    if [[ "${preexec_functions[1]}" != _figo_preexec ]]; then
      preexec_functions=(_figo_preexec ${preexec_functions:#_figo_preexec})
    fi
    _figo_wrap_prompts
    return $figo_status
  }

  _figo_preexec() {
    local REPLY
    _figo_escape "$1"
    builtin print -rn -u $_figo_fd -- "${_figo_prefix}PreExec=${REPLY}"$'\a'
    _figo_unwrap_prompts
  }

  # zsh knows exactly what is on the command line and where the cursor is, so it reports it
  # rather than leaving the wrapper to read it off the screen. \c marks the cursor.
  _figo_report_buffer() {
    [[ "$CONTEXT" == start || "$CONTEXT" == cont ]] || return 0
    local left="${PREBUFFER}${LBUFFER}" REPLY
    local current="${left}"$'\0'"${RBUFFER}"
    [[ "$current" == "$_figo_last_buffer" ]] && return 0
    _figo_last_buffer="$current"
    _figo_escape "$left"
    left="$REPLY"
    _figo_escape "$RBUFFER"
    builtin print -rn -u $_figo_fd -- "${_figo_prefix}Buffer=${left}\\c${REPLY}"$'\a'
  }

  typeset -ga precmd_functions preexec_functions
  precmd_functions=(${precmd_functions:#_figo_precmd} _figo_precmd)
  preexec_functions=(_figo_preexec ${preexec_functions:#_figo_preexec})

  if autoload -Uz add-zle-hook-widget 2>/dev/null; then
    add-zle-hook-widget line-init _figo_report_buffer 2>/dev/null
    add-zle-hook-widget line-pre-redraw _figo_report_buffer 2>/dev/null
  fi
fi
