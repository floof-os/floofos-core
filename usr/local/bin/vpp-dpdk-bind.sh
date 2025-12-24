#!/bin/bash

modprobe vfio-pci 2>/dev/null || true
modprobe uio_pci_generic 2>/dev/null || true

if [ -d /sys/module/vfio ]; then
    echo 1 > /sys/module/vfio/parameters/enable_unsafe_noiommu_mode 2>/dev/null || true
fi

get_pci_address() {
    local DEV_PATH="$1"
    local RESOLVED=$(readlink -f "$DEV_PATH")
    
    if echo "$RESOLVED" | grep -qE '/virtio[0-9]+$'; then
        echo "$RESOLVED" | grep -oE '[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9a-f]' | tail -1
    else
        basename "$RESOLVED"
    fi
}

PCI_DEVICES=""
for dev in /sys/class/net/*/device; do
    [ -L "$dev" ] || continue
    IFACE=$(basename $(dirname $dev))
    [ "$IFACE" = "lo" ] && continue
    PCI=$(get_pci_address "$dev")
    [ -n "$PCI" ] && echo "$PCI" | grep -qE '^[0-9a-f]{4}:' && PCI_DEVICES="$PCI_DEVICES $PCI"
done

[ -z "$PCI_DEVICES" ] && {
    PCI_DEVICES=$(lspci -D 2>/dev/null | grep -E 'Ethernet|Network' | awk '{print $1}')
}

bind_to_dpdk() {
    local PCI_ADDR=$1
    local IFACE=""
    
    for net in /sys/bus/pci/devices/$PCI_ADDR/net/*; do
        [ -d "$net" ] && IFACE=$(basename "$net") && break
    done
    
    [ -n "$IFACE" ] && ip link set "$IFACE" down 2>/dev/null
    
    local CURRENT_DRIVER=""
    [ -L "/sys/bus/pci/devices/$PCI_ADDR/driver" ] && \
        CURRENT_DRIVER=$(basename $(readlink /sys/bus/pci/devices/$PCI_ADDR/driver))
    
    [ "$CURRENT_DRIVER" = "vfio-pci" ] || [ "$CURRENT_DRIVER" = "uio_pci_generic" ] && return 0
    
    [ -n "$CURRENT_DRIVER" ] && {
        echo "$PCI_ADDR" > /sys/bus/pci/devices/$PCI_ADDR/driver/unbind 2>/dev/null || true
        sleep 0.3
    }
    
    local VENDOR_ID=$(cat /sys/bus/pci/devices/$PCI_ADDR/vendor 2>/dev/null | sed 's/0x//')
    local DEVICE_ID=$(cat /sys/bus/pci/devices/$PCI_ADDR/device 2>/dev/null | sed 's/0x//')
    
    if [ -d /sys/bus/pci/drivers/vfio-pci ]; then
        echo "$VENDOR_ID $DEVICE_ID" > /sys/bus/pci/drivers/vfio-pci/new_id 2>/dev/null || true
        echo "$PCI_ADDR" > /sys/bus/pci/drivers/vfio-pci/bind 2>/dev/null || {
            echo "$VENDOR_ID $DEVICE_ID" > /sys/bus/pci/drivers/uio_pci_generic/new_id 2>/dev/null || true
            echo "$PCI_ADDR" > /sys/bus/pci/drivers/uio_pci_generic/bind 2>/dev/null || true
        }
    else
        echo "$VENDOR_ID $DEVICE_ID" > /sys/bus/pci/drivers/uio_pci_generic/new_id 2>/dev/null || true
        echo "$PCI_ADDR" > /sys/bus/pci/drivers/uio_pci_generic/bind 2>/dev/null || true
    fi
}

for PCI in $PCI_DEVICES; do
    bind_to_dpdk "$PCI"
done

exit 0
