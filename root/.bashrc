# FloofOS - Fast Line-rate Offload On Fabric Operating System
# Copyright (C) 2025 FloofOS Networks <dev@floofos.io>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License.

export PATH=$PATH:/usr/local/go/bin

PS1='\u@\h:\w\$ '

if [ -f ~/.bash_aliases ]; then
    . ~/.bash_aliases
fi

if [[ -t 0 && -z "$FLOOFCTL_SHELL" ]]; then
    export FLOOFCTL_SHELL=1
    if [ -x /usr/local/bin/cli ]; then
        /usr/local/bin/cli || echo "CLI exited, returning to shell"
    fi
fi
