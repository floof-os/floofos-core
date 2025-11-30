# FloofOS - Fast Line-rate Offload On Fabric Operating System
# Copyright (C) 2025 FloofOS Networks <dev@floofos.io>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License.

# Auto-launch FloofOS CLI on login
if [[ $- == *i* ]] && [[ -z "$FLOOFOS_CLI_LAUNCHED" ]]; then
    export FLOOFOS_CLI_LAUNCHED=1
    # Launch CLI if available
    if command -v cli >/dev/null 2>&1; then
        exec cli
    fi
fi

# If CLI exited, show normal bash prompt
export PS1='\[\033[01;32m\]floofos@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '

# Enable bash completion
if [ -f /etc/bash_completion ]; then
    . /etc/bash_completion
fi

# Aliases
alias ll='ls -lah'
alias la='ls -A'
alias l='ls -CF'
