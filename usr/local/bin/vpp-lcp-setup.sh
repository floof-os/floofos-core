#!/bin/bash

# FloofOS - Fast Line-rate Offload On Fabric Operating System
# Copyright (C) 2025 FloofOS Networks <dev@floofos.io>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License.

MAX_WAIT=30
WAITED=0

while [ ! -S /run/vpp/cli.sock ] && [ $WAITED -lt $MAX_WAIT ]; do
    sleep 1
    WAITED=$((WAITED + 1))
done

if [ ! -S /run/vpp/cli.sock ]; then
    exit 1
fi

sleep 2

vpp_to_linux_name() {
    local VPP_IF="$1"
    local IDX="$2"
    
    case "$VPP_IF" in
        GigabitEthernet*)
            # GigabitEthernet0/3/0 → ge0
            echo "ge${IDX}"
            ;;
        TenGigabitEthernet*)
            # TenGigabitEthernet0/0/0 → xe0 (10G = X)
            echo "xe${IDX}"
            ;;
        TwentyFiveGigabitEthernet*)
            # 25G → tf0
            echo "tf${IDX}"
            ;;
        FortyGigabitEthernet*)
            # 40G → fo0
            echo "fo${IDX}"
            ;;
        FiftyGigabitEthernet*)
            # 50G → fi0
            echo "fi${IDX}"
            ;;
        HundredGigabitEthernet*)
            # 100G → ce0 (C = 100)
            echo "ce${IDX}"
            ;;
        TwoHundredGigabitEthernet*)
            # 200G → cc0
            echo "cc${IDX}"
            ;;
        FourHundredGigabitEthernet*)
            # 400G → cd0
            echo "cd${IDX}"
            ;;
        VirtIO*)
            # VirtIO (Proxmox/KVM) → vio0
            echo "vio${IDX}"
            ;;
        vmxnet3*)
            # VMware → vmx0
            echo "vmx${IDX}"
            ;;
        *)
            # Fallback
            echo "eth${IDX}"
            ;;
    esac
}

declare -A TYPE_COUNTERS

INTERFACES=$(vppctl show interface 2>/dev/null | grep -E '^(Gigabit|TenGigabit|TwentyFiveGigabit|FortyGigabit|FiftyGigabit|HundredGigabit|TwoHundredGigabit|FourHundredGigabit|VirtIO|vmxnet3)' | awk '{print $1}')

for IFACE in $INTERFACES; do
    EXISTING=$(vppctl show lcp 2>/dev/null | grep "$IFACE" | wc -l)
    
    if [ "$EXISTING" -eq 0 ]; then
        TYPE_PREFIX=$(echo "$IFACE" | sed 's/[0-9/].*$//')
        
        if [ -z "${TYPE_COUNTERS[$TYPE_PREFIX]}" ]; then
            TYPE_COUNTERS[$TYPE_PREFIX]=0
        fi
        
        IDX=${TYPE_COUNTERS[$TYPE_PREFIX]}
        HOST_IF=$(vpp_to_linux_name "$IFACE" "$IDX")
        
        vppctl lcp create "$IFACE" host-if "$HOST_IF" 2>/dev/null
        vppctl set interface state "$IFACE" up 2>/dev/null
        
        TYPE_COUNTERS[$TYPE_PREFIX]=$((IDX + 1))
    fi
done

exit 0
