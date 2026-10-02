# Figo shell integration for fish, second half. Loaded last from ~/.config/fish/conf.d.
#
# Tells the pty wrapper what the shell is doing through private escape sequences of the form
#   ESC ] 6977 ; <session id> ; <payload> BEL
# The wrapper removes them from the output, so the terminal never sees them.

if status is-interactive
    and set -q FIGO_SESSION_ID
    and not set -q FIGO_HELPER
    and not set -q _figo_loaded

    set -g _figo_loaded 1
    set -g _figo_prefix \e"]6977;$FIGO_SESSION_ID;"
    set -g _figo_last_env ""
    set -g _figo_last_aliases ""

    # Makes a value safe to put inside an escape sequence.
    function _figo_escape
        string replace -a '\\' '\\\\' -- "$argv[1]" \
            | string replace -a \e '\\e' \
            | string replace -a \a '\\a' \
            | string replace -a \r '\\r' \
            | string replace -a \t '\\t' \
            | string join '\\n'
    end

    # Markers around the prompt tell the wrapper which cells are prompt and, with NewCmd, where
    # the command line begins. The user's prompt function is kept under another name and called
    # from a wrapper; if something redefines fish_prompt later, it is wrapped again.
    #
    # This has to keep working when another tool wraps the prompt the same way (Fig and its
    # successors do). Such a tool saves whatever fish_prompt is at the time under a name of its
    # own and calls that from its wrapper. So a copy of Figo's wrapper can end up inside theirs,
    # and if theirs were then saved here as "the user's prompt", each would call the other until
    # fish runs out of stack. Two things prevent that: a foreign wrapper is kept apart from the
    # real prompt, and a wrapper that is reached while the markers are already being written
    # draws the real prompt and nothing else.
    function _figo_wrap_prompts
        if not functions -q fish_prompt
            function fish_prompt
                printf '%s> ' (prompt_pwd)
            end
        end
        if _figo_is_wrapper fish_prompt _figo_in_prompt
            # Nothing is wrapped around Figo's wrapper any more.
            functions -e _figo_outer_prompt
        else
            if _figo_calls_wrapper fish_prompt _figo_in_prompt
                functions -e _figo_outer_prompt
                functions -c fish_prompt _figo_outer_prompt
            else
                functions -e _figo_user_prompt
                functions -e _figo_outer_prompt
                functions -c fish_prompt _figo_user_prompt
            end
            function fish_prompt
                set -l figo_status $status
                if set -q _figo_in_prompt
                    _figo_set_status $figo_status
                    _figo_user_prompt
                    return
                end
                # Only the function fish itself calls goes through a foreign wrapper; a copy of
                # this function that such a wrapper holds is on the inside of it.
                set -l figo_draw _figo_user_prompt
                if test (status current-function) = fish_prompt; and functions -q _figo_outer_prompt
                    set figo_draw _figo_outer_prompt
                end
                set -g _figo_in_prompt 1
                printf '%sStartPrompt\a' $_figo_prefix
                # Give the user's prompt the exit status it expects to see.
                _figo_set_status $figo_status
                $figo_draw
                set -e _figo_in_prompt
                printf '%sEndPrompt\a%sNewCmd\a' $_figo_prefix $_figo_prefix
            end
        end

        if functions -q fish_right_prompt
            if _figo_is_wrapper fish_right_prompt _figo_in_right_prompt
                functions -e _figo_outer_right_prompt
            else
                if _figo_calls_wrapper fish_right_prompt _figo_in_right_prompt
                    functions -e _figo_outer_right_prompt
                    functions -c fish_right_prompt _figo_outer_right_prompt
                else
                    functions -e _figo_user_right_prompt
                    functions -e _figo_outer_right_prompt
                    functions -c fish_right_prompt _figo_user_right_prompt
                end
                function fish_right_prompt
                    set -l figo_status $status
                    if set -q _figo_in_right_prompt
                        _figo_set_status $figo_status
                        _figo_user_right_prompt
                        return
                    end
                    set -l figo_draw _figo_user_right_prompt
                    if test (status current-function) = fish_right_prompt; and functions -q _figo_outer_right_prompt
                        set figo_draw _figo_outer_right_prompt
                    end
                    set -g _figo_in_right_prompt 1
                    printf '%sStartPrompt\a' $_figo_prefix
                    _figo_set_status $figo_status
                    $figo_draw
                    set -e _figo_in_right_prompt
                    printf '%sEndPrompt\a' $_figo_prefix
                end
            end
        end
    end

    # True when the function is Figo's wrapper (under any name); `marker` is the variable name
    # only that wrapper uses.
    function _figo_is_wrapper --argument-names name marker
        string match -q "*$marker*" -- (functions $name)
    end

    # True when the function calls a copy of Figo's wrapper, which makes it another tool's
    # wrapper around ours rather than a prompt of the user's.
    function _figo_calls_wrapper --argument-names name marker
        for word in (functions $name | string match -ra '[A-Za-z_][A-Za-z0-9_]*')
            test "$word" = "$name"; and continue
            if functions -q -- $word; and string match -q "*$marker*" -- (functions $word)
                return 0
            end
        end
        return 1
    end

    function _figo_set_status
        return $argv[1]
    end

    function _figo_precmd --on-event fish_prompt
        set -l figo_status $status
        # A prompt that was interrupted while drawing must not leave the next one without markers.
        set -e _figo_in_prompt
        set -e _figo_in_right_prompt
        set -l out "$_figo_prefix"PreCmd\a"$_figo_prefix"ExitCode=$figo_status\a
        set out "$out$_figo_prefix"Dir=(_figo_escape "$PWD")\a
        set out "$out$_figo_prefix"Shell=fish\a
        set out "$out$_figo_prefix"ShellPath=(_figo_escape (status fish-path))\a
        set out "$out$_figo_prefix"PID=$fish_pid\a
        set out "$out$_figo_prefix"TTY=(tty 2>/dev/null)\a
        set out "$out$_figo_prefix"User=(_figo_escape "$USER")\a
        set out "$out$_figo_prefix"FishSuggestionColor="$fish_color_autosuggestion"\a

        # The exported environment and the aliases, so suggestions are computed with what this
        # shell would actually run. Sent only when changed.
        set -l snapshot ""
        for name in (set --names --export)
            set -l value
            if string match -q '*PATH' -- $name
                set value (string join : -- $$name)
            else
                set value (string join ' ' -- $$name)
            end
            set snapshot "$snapshot$_figo_prefix"Var=$name=(_figo_escape "$value")\a
        end
        if test "$snapshot" != "$_figo_last_env"
            set -g _figo_last_env "$snapshot"
            set out "$out$_figo_prefix"EnvStart\a"$snapshot$_figo_prefix"EnvEnd\a
        end

        set snapshot (alias | string collect)
        if test "$snapshot" != "$_figo_last_aliases"
            set -g _figo_last_aliases "$snapshot"
            set out "$out$_figo_prefix"Aliases=(_figo_escape "$snapshot")\a
        end

        printf '%s' "$out"
        _figo_wrap_prompts
    end

    function _figo_preexec --on-event fish_preexec
        printf '%sPreExec=%s\a' $_figo_prefix (_figo_escape "$argv[1]")
    end

    _figo_wrap_prompts
end
