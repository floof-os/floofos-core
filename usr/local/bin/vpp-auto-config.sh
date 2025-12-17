#!/bin/bash

LOG="/var/log/vpp/auto-config.log"
exec > >(tee -a "$LOG") 2>&1

TEMPLATE="/etc/vpp/startup.conf.template"
CONF="/etc/vpp/startup.conf"

TOTAL_RAM=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
FREE_RAM=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
CPU_CORES=$(nproc)
CPU_SOCKETS=$(lscpu | grep "Socket(s):" | awk '{print $2}')
NUMA_NODES=$(lscpu | grep "NUMA node(s):" | awk '{print $3}')
[ -z "$CPU_SOCKETS" ] && CPU_SOCKETS=1
[ -z "$NUMA_NODES" ] && NUMA_NODES=1

CPU_MODEL=$(lscpu | grep "Model name:" | cut -d':' -f2 | xargs)
HAS_AVX512=$(grep -o 'avx512' /proc/cpuinfo | head -1)
[ -n "$HAS_AVX512" ] && CPU_FEATURES="AVX-512" || CPU_FEATURES="AVX2"

IS_VM=0
if grep -qE 'hypervisor|VMware|VirtualBox|QEMU|Xen' /proc/cpuinfo 2>/dev/null || \
   dmidecode -s system-product-name 2>/dev/null | grep -qiE 'virtual|vmware|virtualbox|qemu|xen|kvm|proxmox'; then
    IS_VM=1
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
PCI_DEVICES=$(echo $PCI_DEVICES | tr ' ' '\n' | sort -u | tr '\n' ' ')
NIC_COUNT=$(echo "$PCI_DEVICES" | wc -w)

[ $NIC_COUNT -eq 0 ] && {
    PCI_DEVICES=$(lspci -D | grep -E 'Ethernet|Network' | awk '{print $1}')
    NIC_COUNT=$(echo "$PCI_DEVICES" | wc -w)
}

declare -A NIC_SPEEDS
MAX_NIC_SPEED=0

for PCI in $PCI_DEVICES; do
    NIC_NAME=$(lspci -s $PCI 2>/dev/null | grep -oP '(2\.5G|2500|10G|25G|40G|50G|100G|200G|400G)')
  
  case "$NIC_NAME" in
    *400G*) SPEED=400000 ;;
    *200G*) SPEED=200000 ;;
    *100G*) SPEED=100000 ;;
    *50G*)  SPEED=50000 ;;
    *40G*)  SPEED=40000 ;;
    *25G*)  SPEED=25000 ;;
    *10G*)  SPEED=10000 ;;
    *2.5G*|*2500*) SPEED=2500 ;;
    *)      SPEED=1000 ;;
  esac
  
  NIC_SPEEDS[$PCI]=$SPEED
  [ $SPEED -gt $MAX_NIC_SPEED ] && MAX_NIC_SPEED=$SPEED
done

TOTAL_NIC_BANDWIDTH=$(($(echo "${NIC_SPEEDS[@]}" | tr ' ' '+' | bc 2>/dev/null || echo "1000")))

if [ $TOTAL_RAM -lt 2048 ]; then
  DEPLOYMENT_PROFILE="micro"
  PROFILE_DESC="Embedded/IoT"
elif [ $TOTAL_RAM -lt 8192 ]; then
  DEPLOYMENT_PROFILE="minimal"
  PROFILE_DESC="Lab/Development"
elif [ $TOTAL_RAM -lt 16384 ]; then
  DEPLOYMENT_PROFILE="small"
  PROFILE_DESC="Small Production"
elif [ $TOTAL_RAM -lt 32768 ]; then
  DEPLOYMENT_PROFILE="medium"
  PROFILE_DESC="Medium Production"
elif [ $TOTAL_RAM -lt 131072 ]; then
  DEPLOYMENT_PROFILE="large"
  PROFILE_DESC="Large Production"
else
  DEPLOYMENT_PROFILE="extreme"
  PROFILE_DESC="Extreme Performance"
fi

if [ $MAX_NIC_SPEED -ge 100000 ]; then
  if [ "$DEPLOYMENT_PROFILE" = "small" ] || [ "$DEPLOYMENT_PROFILE" = "medium" ]; then
    DEPLOYMENT_PROFILE="large"
    PROFILE_DESC="Large Production (100G+ NICs)"
  fi

  if [ $TOTAL_RAM -ge 65536 ] && [ $CPU_CORES -ge 32 ]; then
    DEPLOYMENT_PROFILE="extreme"
    PROFILE_DESC="Extreme Performance (100G+ NICs)"
  fi
fi

if [ $CPU_CORES -le 4 ]; then
  RX_QUEUES_PER_NIC=2
elif [ $CPU_CORES -le 16 ]; then
  RX_QUEUES_PER_NIC=4
elif [ $CPU_CORES -le 32 ]; then
  RX_QUEUES_PER_NIC=8
else
  RX_QUEUES_PER_NIC=16
fi

RX_QUEUES=$((NIC_COUNT * RX_QUEUES_PER_NIC))

case "$DEPLOYMENT_PROFILE" in
  micro)
    BUFFERS_PER_NUMA=8192
    BUFFER_SCALE=512
    ;;
  minimal)
    BUFFERS_PER_NUMA=16384
    BUFFER_SCALE=1024
    ;;
  small)
    BUFFERS_PER_NUMA=$((RX_QUEUES * 1024 + NIC_COUNT * 512))
    [ $BUFFERS_PER_NUMA -lt 32768 ] && BUFFERS_PER_NUMA=32768
    BUFFER_SCALE=1024
    ;;
  medium)
    BUFFERS_PER_NUMA=$((RX_QUEUES * 2048 + NIC_COUNT * 1024))
    [ $BUFFERS_PER_NUMA -lt 65536 ] && BUFFERS_PER_NUMA=65536
    BUFFER_SCALE=2048
    ;;
  large)
    BUFFERS_PER_NUMA=$((RX_QUEUES * 4096 + NIC_COUNT * 2048))
    [ $BUFFERS_PER_NUMA -lt 131072 ] && BUFFERS_PER_NUMA=131072
    BUFFER_SCALE=4096
    ;;
  extreme)
    BUFFERS_PER_NUMA=$((RX_QUEUES * 8192 + NIC_COUNT * 4096))
    [ $BUFFERS_PER_NUMA -lt 524288 ] && BUFFERS_PER_NUMA=524288
    BUFFER_SCALE=8192

    if [ $MAX_NIC_SPEED -ge 100000 ]; then
      BUFFERS_PER_NUMA=$((BUFFERS_PER_NUMA * 2))
    fi
    ;;
esac

if [ "$DEPLOYMENT_PROFILE" = "micro" ] || [ "$DEPLOYMENT_PROFILE" = "minimal" ]; then
  SAFETY_MARGIN="1.5"
else
  SAFETY_MARGIN="2.5"
fi

BUFFERS_PER_NUMA=$(echo "$BUFFERS_PER_NUMA * $SAFETY_MARGIN" | bc | cut -d'.' -f1)

[ -z "$BUFFERS_PER_NUMA" ] && BUFFERS_PER_NUMA=16384
[ $BUFFERS_PER_NUMA -lt 8192 ] && BUFFERS_PER_NUMA=8192

BUFFER_SIZE_BYTES=9216
BUFFER_MEM_MB=$(( (BUFFERS_PER_NUMA * BUFFER_SIZE_BYTES * NUMA_NODES) / (1024 * 1024) ))

case "$DEPLOYMENT_PROFILE" in
  micro)
    HEAP_SIZE_MB=512
    ;;
  minimal)
    HEAP_SIZE_MB=1024
    ;;
  small)
    HEAP_SIZE_MB=2048
    ;;
  medium)
    HEAP_SIZE_MB=4096
    ;;
  large)
    HEAP_SIZE_MB=8192
    ;;
  extreme)
    HEAP_SIZE_MB=16384
    ;;
esac

if [ $CPU_CORES -le 4 ]; then
  MAIN_CORE=0
  WORKER_CORES=$((CPU_CORES - 1))
  SKIP_CORES=0
elif [ $CPU_CORES -le 16 ]; then
  MAIN_CORE=0
  WORKER_CORES=$((CPU_CORES - 2))
  SKIP_CORES=0
else
  MAIN_CORE=1
  WORKER_CORES=$((CPU_CORES - 3))
  SKIP_CORES=2
fi

BASE_STATSEG=32
STATSEG_SIZE=$(( BASE_STATSEG + (WORKER_CORES * 16) + (NIC_COUNT * 8) ))

STATSEG_SIZE=$(awk "BEGIN {print 2^(int(log($STATSEG_SIZE)/log(2))+1)}")

[ $STATSEG_SIZE -lt 64 ] && STATSEG_SIZE=64
[ $STATSEG_SIZE -gt 512 ] && STATSEG_SIZE=512

API_MEM=128
OVERHEAD_PERCENT=15

BASE_MEM=$((HEAP_SIZE_MB + BUFFER_MEM_MB + STATSEG_SIZE + API_MEM))
OVERHEAD_MB=$(( (BASE_MEM * OVERHEAD_PERCENT) / 100 ))
TOTAL_HUGE_MEM_MB=$((BASE_MEM + OVERHEAD_MB))

NR_HUGEPAGES=$((TOTAL_HUGE_MEM_MB / 2))

[ $NR_HUGEPAGES -lt 512 ] && NR_HUGEPAGES=512

MAX_HUGEPAGES=$(( (FREE_RAM * 70 / 100) / 2 ))
if [ $NR_HUGEPAGES -gt $MAX_HUGEPAGES ]; then
  NR_HUGEPAGES=$MAX_HUGEPAGES
fi

VM_MAX_MAP_COUNT=$((NR_HUGEPAGES * 2 + 1024))
[ $VM_MAX_MAP_COUNT -lt 16384 ] && VM_MAX_MAP_COUNT=16384

if [ $NR_HUGEPAGES -gt 8192 ]; then
  VM_MAX_MAP_COUNT=$((NR_HUGEPAGES * 3 + 2000))
fi

KERNEL_SHMMAX=$((NR_HUGEPAGES * 2 * 1024 * 1024))

if [ "$DEPLOYMENT_PROFILE" = "minimal" ]; then
  NETLINK_MEM=67108864
elif [ "$DEPLOYMENT_PROFILE" = "small" ]; then
  NETLINK_MEM=67108864
elif [ "$DEPLOYMENT_PROFILE" = "medium" ]; then
  NETLINK_MEM=134217728
elif [ "$DEPLOYMENT_PROFILE" = "large" ]; then
  NETLINK_MEM=268435456 
else
  NETLINK_MEM=536870912
fi

cat > /etc/sysctl.d/80-vpp.conf <<EOFSYSCTL
vm.nr_hugepages=$NR_HUGEPAGES
vm.max_map_count=$VM_MAX_MAP_COUNT
vm.hugetlb_shm_group=0
kernel.shmmax=$KERNEL_SHMMAX
EOFSYSCTL

cat > /etc/sysctl.d/81-vpp-netlink.conf <<EOFNETLINK
net.core.rmem_default=$NETLINK_MEM
net.core.wmem_default=$NETLINK_MEM
net.core.rmem_max=$((NETLINK_MEM * 2))
net.core.wmem_max=$((NETLINK_MEM * 2))
net.core.netdev_max_backlog=5000
net.core.netdev_budget=600
EOFNETLINK

sysctl -p -f /etc/sysctl.d/80-vpp.conf >/dev/null 2>&1
sysctl -p -f /etc/sysctl.d/81-vpp-netlink.conf >/dev/null 2>&1

if [ $SKIP_CORES -gt 0 ]; then
  WORKER_LIST=$(seq -s, $((SKIP_CORES + MAIN_CORE + 1)) $((SKIP_CORES + MAIN_CORE + WORKER_CORES)))
else
  WORKER_LIST=$(seq -s, $((MAIN_CORE + 1)) $((MAIN_CORE + WORKER_CORES)))
fi

if [ "$DEPLOYMENT_PROFILE" = "large" ] || [ "$DEPLOYMENT_PROFILE" = "extreme" ]; then
  SCHEDULER_POLICY="fifo"
  SCHEDULER_PRIORITY=50
else
  SCHEDULER_POLICY=""
  SCHEDULER_PRIORITY=""
fi

case "$DEPLOYMENT_PROFILE" in
  micro|minimal)
    RX_DESC=1024
    TX_DESC=1024
    ;;
  small)
    RX_DESC=2048
    TX_DESC=2048
    ;;
  medium|large)
    RX_DESC=4096
    TX_DESC=4096
    ;;
  extreme)
    RX_DESC=8192
    TX_DESC=8192
    ;;
esac

if [ $MAX_NIC_SPEED -ge 100000 ]; then
  RX_DESC=8192
  TX_DESC=8192
fi

RSS_QUEUES=$RX_QUEUES_PER_NIC

modprobe vfio-pci 2>/dev/null || true
modprobe uio_pci_generic 2>/dev/null || true

if [ -d /sys/module/vfio ]; then
    echo 1 > /sys/module/vfio/parameters/enable_unsafe_noiommu_mode 2>/dev/null || true
fi

bind_to_dpdk() {
    local PCI_ADDR=$1
    local IFACE=""
    
    for net in /sys/bus/pci/devices/$PCI_ADDR/net/*; do
        [ -d "$net" ] && IFACE=$(basename "$net") && break
    done
    
    if [ -n "$IFACE" ]; then
        ip link set "$IFACE" down 2>/dev/null || true
    fi
    
    local CURRENT_DRIVER=""
    if [ -L "/sys/bus/pci/devices/$PCI_ADDR/driver" ]; then
        CURRENT_DRIVER=$(basename $(readlink /sys/bus/pci/devices/$PCI_ADDR/driver))
    fi
    
    if [ "$CURRENT_DRIVER" = "vfio-pci" ] || [ "$CURRENT_DRIVER" = "uio_pci_generic" ]; then
        return 0
    fi
    
    if [ -n "$CURRENT_DRIVER" ]; then
        echo "$PCI_ADDR" > /sys/bus/pci/devices/$PCI_ADDR/driver/unbind 2>/dev/null || true
        sleep 0.5
    fi
    
    local VENDOR_ID=$(cat /sys/bus/pci/devices/$PCI_ADDR/vendor 2>/dev/null | sed 's/0x//')
    local DEVICE_ID=$(cat /sys/bus/pci/devices/$PCI_ADDR/device 2>/dev/null | sed 's/0x//')
    
    if [ -d /sys/bus/pci/drivers/vfio-pci ]; then
        echo "$VENDOR_ID $DEVICE_ID" > /sys/bus/pci/drivers/vfio-pci/new_id 2>/dev/null || true
        sleep 0.2
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

cp "$TEMPLATE" "$CONF"

if [ $IS_VM -eq 1 ]; then
  sed -i '/interactive/a\  poll-sleep-usec 100' "$CONF"
fi

sed -i "/^socksvr {/,/^}/ {
  /^}/a\\
\\
statseg {\\
  size ${STATSEG_SIZE}M\\
  page-size default-hugepage\\
  per-node-counters on\\
  update-interval 300\\
}
}" "$CONF"

sed -i "/^socksvr {/,/^}/ {
  /^}/a\\
\\
buffers {\\
  buffers-per-numa ${BUFFERS_PER_NUMA}\\
  default data-size 9216\\
  page-size default-hugepage\\
}
}" "$CONF"

sed -i "/^socksvr {/,/^}/ {
  /^}/a\\
\\
memory {\\
  main-heap-size ${HEAP_SIZE_MB}M\\
  main-heap-page-size default-hugepage\\
}
}" "$CONF"

sed -i "/^socksvr {/,/^}/ {
  /^}/a\\
\\
cpu {\\
  main-core $MAIN_CORE\\
  corelist-workers $WORKER_LIST\\
}
}" "$CONF"

if [ -n "$SCHEDULER_POLICY" ]; then
  sed -i "/corelist-workers/a\\
  scheduler-policy $SCHEDULER_POLICY\\
  scheduler-priority $SCHEDULER_PRIORITY" "$CONF"
fi

if [ $SKIP_CORES -gt 0 ]; then
  sed -i "/corelist-workers/a\\
  skip-cores $SKIP_CORES" "$CONF"
fi

for DEV in $PCI_DEVICES; do
  sed -i "/^dpdk {/a\\
  dev $DEV {\\
    num-rx-queues $RSS_QUEUES\\
    num-tx-queues $RSS_QUEUES\\
    num-rx-desc $RX_DESC\\
    num-tx-desc $TX_DESC\\
  }" "$CONF"
done

if [ "$DEPLOYMENT_PROFILE" != "minimal" ] && [ "$DEPLOYMENT_PROFILE" != "micro" ]; then
  sed -i "/^logging {/i\\
nat {\\n  endpoint-dependent\\n  max translations per thread 1048576\\n}\\n\\nsession {\\n  evt_qs_memfd_seg\\n  event-queue-length 16384\\n  preallocated-sessions 1024\\n  v4-session-table-buckets 20000\\n  v4-session-table-memory 64M\\n  v6-session-table-buckets 20000\\n  v6-session-table-memory 64M\\n}\\n\\nacl-plugin {\\n  use tuple merge 1\\n  hash lookup heap size 512M\\n}\\n" "$CONF"
fi

if [ "$DEPLOYMENT_PROFILE" != "micro" ] && [ "$DEPLOYMENT_PROFILE" != "minimal" ]; then
  
  if [ $SKIP_CORES -gt 0 ]; then
    IRQ_TARGET_CORE=0
  else
    IRQ_TARGET_CORE=1
  fi
  
  IRQ_COUNT=0
  for PCI in $PCI_DEVICES; do
    BUS_ID=$(echo $PCI | cut -d':' -f2-)
    
    IRQ_NUMS=$(grep "$BUS_ID" /proc/interrupts 2>/dev/null | awk -F: '{print $1}' | tr -d ' ')
    
    for IRQ in $IRQ_NUMS; do
      if [ -n "$IRQ" ] && [ -d "/proc/irq/$IRQ" ]; then
        echo $IRQ_TARGET_CORE > /proc/irq/$IRQ/smp_affinity_list 2>/dev/null && {
          IRQ_COUNT=$((IRQ_COUNT + 1))
        }
      fi
    done
  done
  
  if [ $IRQ_COUNT -gt 0 ]; then
    
    cat > /etc/systemd/system/vpp-irq-affinity.service <<EOFIRQ
[Unit]
Description=VPP IRQ Affinity Tuning
After=network-pre.target
Before=vpp.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/vpp-irq-affinity.sh

[Install]
WantedBy=multi-user.target
EOFIRQ

    cat > /usr/local/bin/vpp-irq-affinity.sh <<EOFIRQSCRIPT
#!/bin/bash
TARGET_CORE=$IRQ_TARGET_CORE

for PCI in $PCI_DEVICES; do
  BUS_ID=\$(echo \$PCI | cut -d':' -f2-)
  IRQ_NUMS=\$(grep "\$BUS_ID" /proc/interrupts 2>/dev/null | awk -F: '{print \$1}' | tr -d ' ')
  
  for IRQ in \$IRQ_NUMS; do
    [ -n "\$IRQ" ] && [ -d "/proc/irq/\$IRQ" ] && {
      echo \$TARGET_CORE > /proc/irq/\$IRQ/smp_affinity_list 2>/dev/null
    }
  done
done
EOFIRQSCRIPT

    chmod +x /usr/local/bin/vpp-irq-affinity.sh
    systemctl daemon-reload
    systemctl enable vpp-irq-affinity.service >/dev/null 2>&1
  fi
fi

REBOOT_REQUIRED=0

if [ "$DEPLOYMENT_PROFILE" = "large" ] || [ "$DEPLOYMENT_PROFILE" = "extreme" ]; then
  if [ $CPU_CORES -ge 8 ]; then
    
    if [ $SKIP_CORES -gt 0 ]; then
      ISOLATE_START=$((SKIP_CORES + 1))
    else
      ISOLATE_START=2
    fi
    
    ISOLATE_END=$((CPU_CORES - 1))
    ISOLATE_RANGE="${ISOLATE_START}-${ISOLATE_END}"
    
    if [ $ISOLATE_START -lt $ISOLATE_END ]; then
      if ! grep -q "isolcpus=" /etc/default/grub 2>/dev/null; then
        cp /etc/default/grub /etc/default/grub.backup
        
        sed -i "s/^GRUB_CMDLINE_LINUX=\"/GRUB_CMDLINE_LINUX=\"isolcpus=${ISOLATE_RANGE} nohz_full=${ISOLATE_RANGE} rcu_nocbs=${ISOLATE_RANGE} /" /etc/default/grub
        
        update-grub >/dev/null 2>&1
        
        REBOOT_REQUIRED=1
            fi
        fi
  fi
fi

exit 0
