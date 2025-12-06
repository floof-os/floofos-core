# FloofOS - Fast Line-rate Offload On Fabric Operating System
# Copyright (C) 2025 FloofOS Networks <dev@floofos.io>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License.

# Prompt: floofos@hostname:path $
export PS1='\[\033[1;32m\]floofos\[\033[0m\]@\[\033[1;33m\]\h\[\033[0m\]:\[\033[1;34m\]\w\[\033[0m\]\$ '

if [[ -t 0 && -z "$FLOOFCTL_SHELL" ]]; then
    export FLOOFCTL_SHELL=1
    if [ -x /usr/local/bin/cli ]; then
        sudo /usr/local/bin/cli || echo "CLI exited, returning to shell"
    fi
fi
