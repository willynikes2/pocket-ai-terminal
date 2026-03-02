# OSC 133 Shell Integration for PAT Thread Mode
# Injected into container's /etc/bash.bashrc
#
# Protocol (FinalTerm/iTerm2, adopted by VS Code, kitty, WezTerm):
#   \e]133;A\a  — Start of prompt
#   \e]133;B\a  — End of prompt, start of command input
#   \e]133;C\a  — Command executed, output follows
#   \e]133;D;N\a — Command finished with exit code N

__pat_prompt_command() {
    local exit_code=$?
    # Mark end of previous command output + start of new prompt
    printf '\e]133;D;%s\a' "$exit_code"
    printf '\e]133;A\a'
}

# Set PROMPT_COMMAND to emit D (with exit code) and A at each prompt
PROMPT_COMMAND='__pat_prompt_command'

# PS1 ends with B marker (end of prompt, user input begins)
PS1='\[\e]133;B\a\]PAT \w> '

# PS0 emits C just before command output appears (Bash 4.4+)
PS0='\[\e]133;C\a\]'
