# Figo shell integration for bash, second half. Sourced at the very bottom of ~/.bashrc.
#
# Tells the pty wrapper what the shell is doing through private escape sequences of the form
#   ESC ] 6977 ; <session id> ; <payload> BEL
# The wrapper removes them from the output, so the terminal never sees them.
#
# bash has no hooks of its own for "a command is about to run" and "a prompt is about to be
# shown", so this relies on bash-preexec (bundled, MIT licence), which builds them from the
# DEBUG trap and PROMPT_COMMAND. Written to work on the bash 3.2 that ships with macOS.

if [[ $- == *i* && -n "${FIGO_SESSION_ID-}" && -z "${FIGO_HELPER-}" && -z "${_figo_loaded-}" ]]; then
  _figo_loaded=1

  _figo_prefix=$'\e]6977;'"${FIGO_SESSION_ID};"
  _figo_start="${_figo_prefix}StartPrompt"$'\a'
  _figo_end="${_figo_prefix}EndPrompt"$'\a'
  _figo_newcmd="${_figo_prefix}NewCmd"$'\a'
  _figo_last_env=""
  _figo_last_aliases=""
  _figo_tty="$(tty 2>/dev/null)"
  # See pre.bash: $BASH can name the account's default shell rather than this one.
  _figo_shell_path="$BASH"
  [[ "${_figo_shell_path##*/}" == bash* ]] || _figo_shell_path="$(type -P bash)"

  # Makes a value safe to put inside an escape sequence. Result in _figo_reply.
  _figo_escape() {
    _figo_reply=${1//\\/\\\\}
    _figo_reply=${_figo_reply//$'\e'/\\e}
    _figo_reply=${_figo_reply//$'\a'/\\a}
    _figo_reply=${_figo_reply//$'\n'/\\n}
    _figo_reply=${_figo_reply//$'\r'/\\r}
    _figo_reply=${_figo_reply//$'\t'/\\t}
  }

  # Markers around the prompt tell the wrapper which cells are prompt and, with NewCmd, where
  # the command line begins. \[ \] tells readline they take up no room.
  _figo_wrap_prompt() {
    [[ "$PS1" == "\[${_figo_start}\]"* ]] || PS1="\[${_figo_start}\]${PS1}\[${_figo_end}${_figo_newcmd}\]"
    [[ "$PS2" == "\[${_figo_start}\]"* ]] || PS2="\[${_figo_start}\]${PS2}\[${_figo_end}\]"
  }

  _figo_unwrap_prompt() {
    PS1=${PS1#"\[${_figo_start}\]"}
    PS1=${PS1%"\[${_figo_end}${_figo_newcmd}\]"}
    PS2=${PS2#"\[${_figo_start}\]"}
    PS2=${PS2%"\[${_figo_end}\]"}
  }

  # Other PROMPT_COMMAND entries (prompt themes) may rebuild PS1 on every prompt, after the
  # precmd functions have run. The wrapping therefore has to be the last thing that happens,
  # just before bash-preexec's own closing entry.
  _figo_arrange_prompt_command() {
    local wrap=_figo_wrap_prompt mode=__bp_interactive_mode
    if (( ${#PROMPT_COMMAND[@]} > 1 )); then
      local last=$(( ${#PROMPT_COMMAND[@]} - 1 )) entry
      local -a rebuilt
      [[ "${PROMPT_COMMAND[last]}" == "$mode" && "${PROMPT_COMMAND[last - 1]}" == "$wrap" ]] && return
      for entry in "${PROMPT_COMMAND[@]}"; do
        [[ "$entry" == "$wrap" || "$entry" == "$mode" ]] || rebuilt+=("$entry")
      done
      PROMPT_COMMAND=("${rebuilt[@]}" "$wrap" "$mode")
    else
      [[ "$PROMPT_COMMAND" == *$'\n'"$wrap"$'\n'"$mode" ]] && return
      local command="$PROMPT_COMMAND"
      command=${command//$'\n'$wrap/}
      command=${command//$'\n'$mode/}
      PROMPT_COMMAND="${command}"$'\n'"$wrap"$'\n'"$mode"
    fi
  }

  _figo_precmd() {
    local figo_status=$?
    local out="${_figo_prefix}PreCmd"$'\a'"${_figo_prefix}ExitCode=${figo_status}"$'\a'
    local name snapshot="" IFS=$' \t\n'

    _figo_escape "$PWD"
    out+="${_figo_prefix}Dir=${_figo_reply}"$'\a'
    out+="${_figo_prefix}Shell=bash"$'\a'
    _figo_escape "$_figo_shell_path"
    out+="${_figo_prefix}ShellPath=${_figo_reply}"$'\a'
    out+="${_figo_prefix}PID=$$"$'\a'
    out+="${_figo_prefix}TTY=${_figo_tty}"$'\a'
    _figo_escape "${USER:-root}"
    out+="${_figo_prefix}User=${_figo_reply}"$'\a'

    # The exported environment and the aliases, so suggestions are computed with what this
    # shell would actually run. Sent only when changed.
    for name in $(compgen -e); do
      _figo_escape "${!name}"
      snapshot+="${_figo_prefix}Var=${name}=${_figo_reply}"$'\a'
    done
    if [[ "$snapshot" != "$_figo_last_env" ]]; then
      _figo_last_env="$snapshot"
      out+="${_figo_prefix}EnvStart"$'\a'"${snapshot}${_figo_prefix}EnvEnd"$'\a'
    fi

    snapshot="$(alias)"
    if [[ "$snapshot" != "$_figo_last_aliases" ]]; then
      _figo_last_aliases="$snapshot"
      _figo_escape "$snapshot"
      out+="${_figo_prefix}Aliases=${_figo_reply}"$'\a'
    fi

    builtin printf '%s' "$out" >/dev/tty 2>/dev/null

    # Keep our hooks where they need to be: other startup code may have added its own since.
    if [[ "${precmd_functions[0]-}" != _figo_precmd ]]; then
      local -a others
      for name in "${precmd_functions[@]}"; do
        [[ "$name" == _figo_precmd ]] || others+=("$name")
      done
      precmd_functions=(_figo_precmd "${others[@]}")
    fi
    if [[ "${preexec_functions[0]-}" != _figo_preexec ]]; then
      local -a others_preexec
      for name in "${preexec_functions[@]}"; do
        [[ "$name" == _figo_preexec ]] || others_preexec+=("$name")
      done
      preexec_functions=(_figo_preexec "${others_preexec[@]}")
    fi

    # On the very first prompt bash-preexec installs itself as the last PROMPT_COMMAND entry,
    # so everything else has already run and the prompt can be wrapped here. From the second
    # prompt on, the dedicated entry arranged below does it.
    _figo_wrap_prompt
    _figo_arrange_prompt_command
    return $figo_status
  }

  _figo_preexec() {
    _figo_escape "$1"
    builtin printf '%s' "${_figo_prefix}PreExec=${_figo_reply}"$'\a' >/dev/tty 2>/dev/null
    _figo_unwrap_prompt
  }

  if [[ -z "${bash_preexec_imported-}" && -f "${BASH_SOURCE[0]%/*}/bash-preexec.sh" ]]; then
    builtin source "${BASH_SOURCE[0]%/*}/bash-preexec.sh"
  fi

  if [[ -n "${bash_preexec_imported-}" ]]; then
    precmd_functions=(_figo_precmd "${precmd_functions[@]}")
    preexec_functions=(_figo_preexec "${preexec_functions[@]}")
  else
    unset _figo_loaded
  fi
fi
