#!/bin/bash

LOG="/var/log/vpp/auto-config.log"
mkdir -p /var/log/vpp
exec > >(tee -a "$LOG") 2>&1

echo "Hello :), FloofOS VPP Tuning started at $(date)"

TEMPLATE="/etc/vpp/startup.conf.template"
CONF="/etc/vpp/startup.conf"

TOTAL_RAM=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
FREE_RAM=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
LOGICAL_CORES=$(nproc)
CPU_SOCKETS=$(lscpu | grep "Socket(s):" | awk '{print $2}')
NUMA_NODES=$(lscpu | grep "NUMA node(s):" | awk '{print $3}')
CORES_PER_SOCKET=$(lscpu | grep "Core(s) per socket:" | awk '{print $4}')
THREADS_PER_CORE=$(lscpu | grep "Thread(s) per core:" | awk '{print $4}')
[ -z "$CPU_SOCKETS" ] && CPU_SOCKETS=1
[ -z "$NUMA_NODES" ] && NUMA_NODES=1
[ -z "$CORES_PER_SOCKET" ] && CORES_PER_SOCKET=$((LOGICAL_CORES / CPU_SOCKETS))
[ -z "$THREADS_PER_CORE" ] && THREADS_PER_CORE=1

PHYSICAL_CORES=$((LOGICAL_CORES / THREADS_PER_CORE))
HT_ENABLED=0
if [ $THREADS_PER_CORE -gt 1 ]; then
    HT_ENABLED=1
    CPU_CORES=$PHYSICAL_CORES
    
    PHYSICAL_CORE_LIST=""
    if [ -d /sys/devices/system/cpu/cpu0/topology ]; then
        for cpu in /sys/devices/system/cpu/cpu[0-9]*/topology/thread_siblings_list; do
            [ -f "$cpu" ] || continue
            first_thread=$(cat "$cpu" | cut -d',' -f1 | cut -d'-' -f1)
            if ! echo "$PHYSICAL_CORE_LIST" | grep -qw "$first_thread"; then
                [ -n "$PHYSICAL_CORE_LIST" ] && PHYSICAL_CORE_LIST="$PHYSICAL_CORE_LIST "
                PHYSICAL_CORE_LIST="${PHYSICAL_CORE_LIST}${first_thread}"
            fi
        done
        PHYSICAL_CORE_LIST=$(echo "$PHYSICAL_CORE_LIST" | tr ' ' '\n' | sort -n | tr '\n' ' ')
    fi
    echo "HT enabled: $LOGICAL_CORES logical, $PHYSICAL_CORES physical cores"
else
    CPU_CORES=$LOGICAL_CORES
    PHYSICAL_CORE_LIST=""
fi

CPU_MODEL=$(lscpu | grep "Model name:" | cut -d':' -f2 | xargs)
HAS_AVX512=$(grep -o 'avx512' /proc/cpuinfo | head -1)
[ -n "$HAS_AVX512" ] && CPU_FEATURES="AVX-512" || CPU_FEATURES="AVX2"

IS_VM=0
if grep -qE 'hypervisor|VMware|VirtualBox|QEMU|Xen' /proc/cpuinfo 2>/dev/null || \
   dmidecode -s system-product-name 2>/dev/null | grep -qiE 'virtual|vmware|virtualbox|qemu|xen|kvm|proxmox'; then
    IS_VM=1
fi

echo "Hardware: $CPU_MODEL"
echo "Sockets: $CPU_SOCKETS, NUMA nodes: $NUMA_NODES, Cores: $CPU_CORES"
echo "RAM: ${TOTAL_RAM}MB, Features: $CPU_FEATURES"
echo "Environment: $([ $IS_VM -eq 1 ] && echo 'Virtual Machine' || echo 'Bare Metal')"

get_physical_cores_for_numa() {
    local node=$1
    local cores=""
    
    if [ $HT_ENABLED -eq 0 ]; then
        if [ -f "/sys/devices/system/node/node${node}/cpulist" ]; then
            cat /sys/devices/system/node/node${node}/cpulist
        else
            local start=$((node * (CPU_CORES / NUMA_NODES)))
            local end=$(( (node + 1) * (CPU_CORES / NUMA_NODES) - 1 ))
            echo "${start}-${end}"
        fi
        return
    fi
    
    for cpu in /sys/devices/system/cpu/cpu[0-9]*/; do
        local cpu_id=$(basename "$cpu" | sed 's/cpu//')
        local cpu_numa=$(cat "$cpu/topology/physical_package_id" 2>/dev/null || echo "0")
        
        [ -f "/sys/devices/system/node/node${node}/cpulist" ] && {
            local numa_cpus=$(cat /sys/devices/system/node/node${node}/cpulist)
            if ! echo "$numa_cpus" | grep -qE "(^|,)${cpu_id}(,|$|-)" 2>/dev/null; then
                echo "$numa_cpus" | tr ',' '\n' | while read range; do
                    if echo "$range" | grep -q '-'; then
                        local rs=$(echo "$range" | cut -d'-' -f1)
                        local re=$(echo "$range" | cut -d'-' -f2)
                        [ $cpu_id -ge $rs ] && [ $cpu_id -le $re ] || continue
                    else
                        [ "$range" = "$cpu_id" ] || continue
                    fi
                    break
                done || continue
            fi
        }
        
        if [ -f "$cpu/topology/thread_siblings_list" ]; then
            local first=$(cat "$cpu/topology/thread_siblings_list" | cut -d',' -f1 | cut -d'-' -f1)
            if [ "$first" = "$cpu_id" ]; then
                [ -n "$cores" ] && cores="$cores,"
                cores="${cores}${cpu_id}"
            fi
        fi
    done
    
    echo "$cores" | tr ',' '\n' | sort -n | tr '\n' ',' | sed 's/,$//'
}

declare -A NUMA_CPUS_START
declare -A NUMA_CPUS_END
declare -A NUMA_CPUS_LIST
declare -A NUMA_PHYSICAL_CORES
declare -A NUMA_MEM_MB
declare -A NUMA_NIC_COUNT
declare -A NUMA_NIC_LIST
declare -A NUMA_BANDWIDTH

for node in $(seq 0 $((NUMA_NODES-1))); do
    NUMA_NIC_COUNT[$node]=0
    NUMA_NIC_LIST[$node]=""
    NUMA_BANDWIDTH[$node]=0
    
    if [ -f "/sys/devices/system/node/node${node}/cpulist" ]; then
        cpulist=$(cat /sys/devices/system/node/node${node}/cpulist)
        NUMA_CPUS_LIST[$node]="$cpulist"
        
        if echo "$cpulist" | grep -q ","; then
            first_range=$(echo "$cpulist" | cut -d',' -f1)
            NUMA_CPUS_START[$node]=$(echo "$first_range" | cut -d'-' -f1)
            last_range=$(echo "$cpulist" | rev | cut -d',' -f1 | rev)
            NUMA_CPUS_END[$node]=$(echo "$last_range" | cut -d'-' -f2)
        elif echo "$cpulist" | grep -q "-"; then
            NUMA_CPUS_START[$node]=$(echo "$cpulist" | cut -d'-' -f1)
            NUMA_CPUS_END[$node]=$(echo "$cpulist" | cut -d'-' -f2)
        else
            NUMA_CPUS_START[$node]=$cpulist
            NUMA_CPUS_END[$node]=$cpulist
        fi
    else
        cores_per_node=$((CPU_CORES / NUMA_NODES))
        NUMA_CPUS_START[$node]=$((node * cores_per_node))
        NUMA_CPUS_END[$node]=$(( (node + 1) * cores_per_node - 1 ))
        NUMA_CPUS_LIST[$node]="${NUMA_CPUS_START[$node]}-${NUMA_CPUS_END[$node]}"
    fi
    
    if [ $HT_ENABLED -eq 1 ]; then
        phys_cores=""
        for cpu_id in $(seq ${NUMA_CPUS_START[$node]} ${NUMA_CPUS_END[$node]}); do
            [ -f "/sys/devices/system/cpu/cpu${cpu_id}/topology/thread_siblings_list" ] || continue
            first=$(cat /sys/devices/system/cpu/cpu${cpu_id}/topology/thread_siblings_list | cut -d',' -f1 | cut -d'-' -f1)
            if [ "$first" = "$cpu_id" ]; then
                [ -n "$phys_cores" ] && phys_cores="$phys_cores,"
                phys_cores="${phys_cores}${cpu_id}"
            fi
        done
        NUMA_PHYSICAL_CORES[$node]="$phys_cores"
    else
        NUMA_PHYSICAL_CORES[$node]="${NUMA_CPUS_START[$node]}-${NUMA_CPUS_END[$node]}"
    fi
    
    if [ -f "/sys/devices/system/node/node${node}/meminfo" ]; then
        NUMA_MEM_MB[$node]=$(awk '/MemTotal/ {print int($4/1024)}' /sys/devices/system/node/node${node}/meminfo)
    else
        NUMA_MEM_MB[$node]=$((TOTAL_RAM / NUMA_NODES))
    fi
    
    echo "NUMA $node: CPUs ${NUMA_CPUS_LIST[$node]}, Memory ${NUMA_MEM_MB[$node]}MB"
done

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
declare -A NIC_NUMA
declare -A NIC_QUEUES
MAX_NIC_SPEED=0
TOTAL_BANDWIDTH=0

for PCI in $PCI_DEVICES; do
    NIC_NAME=$(lspci -s $PCI 2>/dev/null | grep -oE '(2\.5G|2500|10G|25G|40G|50G|100G|200G|400G)' | head -1)
    
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
    TOTAL_BANDWIDTH=$((TOTAL_BANDWIDTH + SPEED))
    [ $SPEED -gt $MAX_NIC_SPEED ] && MAX_NIC_SPEED=$SPEED
    
    numa_node=-1
    if [ -f "/sys/bus/pci/devices/$PCI/numa_node" ]; then
        numa_node=$(cat /sys/bus/pci/devices/$PCI/numa_node 2>/dev/null)
    fi
    [ "$numa_node" = "-1" ] && numa_node=0
    [ $numa_node -ge $NUMA_NODES ] && numa_node=0
    
    NIC_NUMA[$PCI]=$numa_node
    NUMA_NIC_COUNT[$numa_node]=$((${NUMA_NIC_COUNT[$numa_node]} + 1))
    NUMA_NIC_LIST[$numa_node]="${NUMA_NIC_LIST[$numa_node]} $PCI"
    NUMA_BANDWIDTH[$numa_node]=$((${NUMA_BANDWIDTH[$numa_node]} + SPEED))
    
    if [ $SPEED -ge 100000 ]; then
        NIC_QUEUES[$PCI]=16
    elif [ $SPEED -ge 40000 ]; then
        NIC_QUEUES[$PCI]=8
    elif [ $SPEED -ge 10000 ]; then
        NIC_QUEUES[$PCI]=4
    elif [ $SPEED -ge 2500 ]; then
        NIC_QUEUES[$PCI]=2
    else
        NIC_QUEUES[$PCI]=1
    fi
    
    echo "NIC $PCI: ${SPEED}Mbps, NUMA $numa_node, Queues ${NIC_QUEUES[$PCI]}"
done

echo "Total bandwidth: ${TOTAL_BANDWIDTH}Mbps across $NIC_COUNT NICs"
for node in $(seq 0 $((NUMA_NODES-1))); do
    echo "NUMA $node: ${NUMA_NIC_COUNT[$node]} NICs, ${NUMA_BANDWIDTH[$node]}Mbps"
done

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

echo "Deployment Profile: $DEPLOYMENT_PROFILE ($PROFILE_DESC)"

declare -A SOCKET_MEM

for node in $(seq 0 $((NUMA_NODES-1))); do
    node_nics="${NUMA_NIC_LIST[$node]}"
    node_bandwidth=${NUMA_BANDWIDTH[$node]}
    node_nic_count=${NUMA_NIC_COUNT[$node]}
    
    case "$DEPLOYMENT_PROFILE" in
        micro)
            base_mem=256
            per_nic_mem=64
            per_gbps_mem=1
            ;;
        minimal)
            base_mem=512
            per_nic_mem=128
            per_gbps_mem=2
            ;;
        small)
            base_mem=1024
            per_nic_mem=256
            per_gbps_mem=4
            ;;
        medium)
            base_mem=2048
            per_nic_mem=512
            per_gbps_mem=8
            ;;
        large)
            base_mem=4096
            per_nic_mem=1024
            per_gbps_mem=16
            ;;
        extreme)
            base_mem=8192
            per_nic_mem=2048
            per_gbps_mem=32
            ;;
    esac
    
    bandwidth_gb=$((node_bandwidth / 1000))
    calculated_mem=$((base_mem + (node_nic_count * per_nic_mem) + (bandwidth_gb * per_gbps_mem)))
    
    power=1
    while [ $power -lt $calculated_mem ]; do
        power=$((power * 2))
    done
    calculated_mem=$power
    
    [ $calculated_mem -lt 512 ] && calculated_mem=512
    
    max_node_mem=$(( ${NUMA_MEM_MB[$node]} * 60 / 100 ))
    [ $calculated_mem -gt $max_node_mem ] && calculated_mem=$max_node_mem
    
    SOCKET_MEM[$node]=$calculated_mem
    echo "NUMA $node socket-mem: ${calculated_mem}MB"
done

SOCKET_MEM_STR=""
for node in $(seq 0 $((NUMA_NODES-1))); do
    [ -n "$SOCKET_MEM_STR" ] && SOCKET_MEM_STR="${SOCKET_MEM_STR},"
    SOCKET_MEM_STR="${SOCKET_MEM_STR}${SOCKET_MEM[$node]}"
done

echo "socket-mem: $SOCKET_MEM_STR"

total_queues=0
for PCI in $PCI_DEVICES; do
    total_queues=$((total_queues + ${NIC_QUEUES[$PCI]}))
done

bandwidth_gbps=$((TOTAL_BANDWIDTH / 1000))

base_buffers=$((total_queues * 2048))

bandwidth_buffers=$((bandwidth_gbps * 1024))

if [ $MAX_NIC_SPEED -ge 100000 ]; then
    burst_factor=4
elif [ $MAX_NIC_SPEED -ge 40000 ]; then
    burst_factor=2
else
    burst_factor=1
fi
bandwidth_buffers=$((bandwidth_buffers * burst_factor))

if [ $base_buffers -gt $bandwidth_buffers ]; then
    BUFFERS_PER_NUMA=$base_buffers
else
    BUFFERS_PER_NUMA=$bandwidth_buffers
fi

case "$DEPLOYMENT_PROFILE" in
    micro)   min_buffers=8192 ;;
    minimal) min_buffers=16384 ;;
    small)   min_buffers=32768 ;;
    medium)  min_buffers=65536 ;;
    large)   min_buffers=131072 ;;
    extreme) min_buffers=262144 ;;
esac

[ $BUFFERS_PER_NUMA -lt $min_buffers ] && BUFFERS_PER_NUMA=$min_buffers

power=1
while [ $power -lt $BUFFERS_PER_NUMA ]; do
    power=$((power * 2))
done
BUFFERS_PER_NUMA=$power

max_buffers=2097152
[ $BUFFERS_PER_NUMA -gt $max_buffers ] && BUFFERS_PER_NUMA=$max_buffers

echo "Buffers: $BUFFERS_PER_NUMA per-numa (queues: $total_queues, bw: ${bandwidth_gbps}Gbps)"

case "$DEPLOYMENT_PROFILE" in
    micro)     base_heap=256 ;;
    minimal)   base_heap=512 ;;
    small)     base_heap=1024 ;;
    medium)    base_heap=2048 ;;
    large)     base_heap=4096 ;;
    extreme)   base_heap=8192 ;;
esac

worker_heap=$((WORKER_CORES * 128))

if [ $MAX_NIC_SPEED -ge 100000 ]; then
    feature_heap=4096
elif [ $MAX_NIC_SPEED -ge 40000 ]; then
    feature_heap=2048
elif [ $MAX_NIC_SPEED -ge 10000 ]; then
    feature_heap=1024
else
    feature_heap=512
fi

HEAP_SIZE_MB=$((base_heap + worker_heap + feature_heap))

power=1
while [ $power -lt $HEAP_SIZE_MB ]; do
    power=$((power * 2))
done
HEAP_SIZE_MB=$power

max_heap=65536
[ $HEAP_SIZE_MB -gt $max_heap ] && HEAP_SIZE_MB=$max_heap

echo "Heap: ${HEAP_SIZE_MB}MB"

MAIN_CORE=0
if [ $CPU_CORES -le 2 ]; then
    WORKER_CORES=1
elif [ $NUMA_NODES -gt 1 ] && [ $IS_VM -eq 0 ]; then
    WORKER_CORES=$((CPU_CORES - NUMA_NODES))
else
    WORKER_CORES=$((CPU_CORES - 1))
fi

MAX_VPP_WORKERS=62
if [ $WORKER_CORES -gt $MAX_VPP_WORKERS ]; then
    echo "Note: Limiting workers from $WORKER_CORES to $MAX_VPP_WORKERS (VPP bitmap limit)"
    WORKER_CORES=$MAX_VPP_WORKERS
fi

echo "CPU: $CPU_CORES cores, $NUMA_NODES NUMA, main=$MAIN_CORE, workers=$WORKER_CORES"

if [ $NUMA_NODES -gt 1 ] && [ $IS_VM -eq 0 ]; then
    total_bw=0
    for node in $(seq 0 $((NUMA_NODES-1))); do
        total_bw=$((total_bw + ${NUMA_BANDWIDTH[$node]}))
    done
    
    declare -A WORKERS_PER_NUMA
    remaining_workers=$WORKER_CORES
    
    if [ $total_bw -eq 0 ]; then
        for node in $(seq 0 $((NUMA_NODES-1))); do
            WORKERS_PER_NUMA[$node]=$((WORKER_CORES / NUMA_NODES))
        done
        WORKERS_PER_NUMA[0]=$((WORKERS_PER_NUMA[0] + WORKER_CORES % NUMA_NODES))
    else
        for node in $(seq 0 $((NUMA_NODES-1))); do
            node_bw=${NUMA_BANDWIDTH[$node]}
            if [ $node_bw -gt 0 ]; then
                node_workers=$(( (WORKER_CORES * node_bw) / total_bw ))
                [ $node_workers -lt 1 ] && node_workers=1
            else
                node_workers=0
            fi
            WORKERS_PER_NUMA[$node]=$node_workers
            remaining_workers=$((remaining_workers - node_workers))
        done
        
        for node in $(seq 0 $((NUMA_NODES-1))); do
            if [ $remaining_workers -gt 0 ] && [ ${NUMA_BANDWIDTH[$node]} -gt 0 ]; then
                WORKERS_PER_NUMA[$node]=$((WORKERS_PER_NUMA[$node] + remaining_workers))
                remaining_workers=0
                break
            fi
        done
    fi
    
    for node in $(seq 0 $((NUMA_NODES-1))); do
        echo "NUMA $node: ${WORKERS_PER_NUMA[$node]} workers, ${NUMA_BANDWIDTH[$node]}Mbps"
    done
    
    WORKER_LIST=""
    SKIPPED_CORES=""
    
    if [ $HT_ENABLED -eq 1 ]; then
        for node in $(seq 0 $((NUMA_NODES-1))); do
            node_workers=${WORKERS_PER_NUMA[$node]}
            [ $node_workers -eq 0 ] && continue
            
            phys_cores="${NUMA_PHYSICAL_CORES[$node]}"
            core_array=($(echo "$phys_cores" | tr ',' ' '))
            
            skip_count=1
            [ $node -gt 0 ] && SKIPPED_CORES="${SKIPPED_CORES} ${core_array[0]}"
            
            added=0
            for core in "${core_array[@]}"; do
                if [ $skip_count -gt 0 ]; then
                    skip_count=$((skip_count - 1))
                    continue
                fi
                [ $added -ge $node_workers ] && break
                [ -n "$WORKER_LIST" ] && WORKER_LIST="${WORKER_LIST},"
                WORKER_LIST="${WORKER_LIST}${core}"
                added=$((added + 1))
            done
        done
    else
        for node in $(seq 0 $((NUMA_NODES-1))); do
            node_workers=${WORKERS_PER_NUMA[$node]}
            [ $node_workers -eq 0 ] && continue
            
            node_start=${NUMA_CPUS_START[$node]}
            node_end=${NUMA_CPUS_END[$node]}
            
            if [ $node -eq 0 ]; then
                worker_start=$((node_start + 1))
            else
                worker_start=$((node_start + 1))
                SKIPPED_CORES="${SKIPPED_CORES} ${node_start}"
            fi
            
            worker_end=$((worker_start + node_workers - 1))
            [ $worker_end -gt $node_end ] && worker_end=$node_end
            
            if [ $worker_start -le $worker_end ]; then
                [ -n "$WORKER_LIST" ] && WORKER_LIST="${WORKER_LIST},"
                if [ $worker_start -eq $worker_end ]; then
                    WORKER_LIST="${WORKER_LIST}${worker_start}"
                else
                    WORKER_LIST="${WORKER_LIST}${worker_start}-${worker_end}"
                fi
            fi
        done
    fi
    
    echo "Workers: $WORKER_LIST (physical cores only)"
    [ -n "$SKIPPED_CORES" ] && echo "Skipped:$SKIPPED_CORES"
else
    if [ $HT_ENABLED -eq 1 ]; then
        phys_cores="${NUMA_PHYSICAL_CORES[0]}"
        core_array=($(echo "$phys_cores" | tr ',' ' '))
        
        WORKER_LIST=""
        added=0
        for core in "${core_array[@]}"; do
            [ "$core" = "$MAIN_CORE" ] && continue
            [ $added -ge $WORKER_CORES ] && break
            [ -n "$WORKER_LIST" ] && WORKER_LIST="${WORKER_LIST},"
            WORKER_LIST="${WORKER_LIST}${core}"
            added=$((added + 1))
        done
    else
        worker_start=$((MAIN_CORE + 1))
        worker_end=$((worker_start + WORKER_CORES - 1))
        
        if [ $worker_start -eq $worker_end ]; then
            WORKER_LIST="$worker_start"
        else
            WORKER_LIST="${worker_start}-${worker_end}"
        fi
    fi
    
    echo "Workers: $WORKER_LIST"
fi

case "$DEPLOYMENT_PROFILE" in
    micro)   base_statseg=64 ;;
    minimal) base_statseg=128 ;;
    small)   base_statseg=256 ;;
    medium)  base_statseg=512 ;;
    large)   base_statseg=1024 ;;
    extreme) base_statseg=2048 ;;
esac

worker_statseg=$((WORKER_CORES * 8))
nic_statseg=$((NIC_COUNT * 16))

STATSEG_SIZE=$((base_statseg + worker_statseg + nic_statseg))

power=1
while [ $power -lt $STATSEG_SIZE ]; do
    power=$((power * 2))
done
STATSEG_SIZE=$power

[ $STATSEG_SIZE -lt 64 ] && STATSEG_SIZE=64

max_statseg=4096
[ $STATSEG_SIZE -gt $max_statseg ] && STATSEG_SIZE=$max_statseg

echo "Statseg: ${STATSEG_SIZE}MB"

BUFFER_SIZE_BYTES=2176
BUFFER_MEM_MB=$(( (BUFFERS_PER_NUMA * BUFFER_SIZE_BYTES * NUMA_NODES) / (1024 * 1024) ))

total_socket_mem=0
for node in $(seq 0 $((NUMA_NODES-1))); do
    total_socket_mem=$((total_socket_mem + ${SOCKET_MEM[$node]}))
done

API_MEM=256
OVERHEAD_PERCENT=25
BASE_MEM=$((HEAP_SIZE_MB + BUFFER_MEM_MB + STATSEG_SIZE + API_MEM + total_socket_mem))
OVERHEAD_MB=$(( (BASE_MEM * OVERHEAD_PERCENT) / 100 ))
TOTAL_HUGE_MEM_MB=$((BASE_MEM + OVERHEAD_MB))

echo "Memory: ${TOTAL_HUGE_MEM_MB}MB total (heap ${HEAP_SIZE_MB}MB, buffers ${BUFFER_MEM_MB}MB, socket-mem ${total_socket_mem}MB)"

NR_HUGEPAGES=$((TOTAL_HUGE_MEM_MB / 2))

case "$DEPLOYMENT_PROFILE" in
    micro)   min_hugepages=256 ;;
    minimal) min_hugepages=512 ;;
    small)   min_hugepages=1024 ;;
    medium)  min_hugepages=2048 ;;
    large)   min_hugepages=4096 ;;
    extreme) min_hugepages=8192 ;;
esac

[ $NR_HUGEPAGES -lt $min_hugepages ] && NR_HUGEPAGES=$min_hugepages

MAX_HUGEPAGES=$(( (FREE_RAM * 80 / 100) / 2 ))
[ $NR_HUGEPAGES -gt $MAX_HUGEPAGES ] && NR_HUGEPAGES=$MAX_HUGEPAGES

power=1
while [ $power -lt $NR_HUGEPAGES ]; do
    power=$((power * 2))
done
NR_HUGEPAGES=$power

echo "Hugepages: $NR_HUGEPAGES ($(( NR_HUGEPAGES * 2 ))MB)"

VM_MAX_MAP_COUNT=$((NR_HUGEPAGES * 3 + 2048))
[ $VM_MAX_MAP_COUNT -lt 65536 ] && VM_MAX_MAP_COUNT=65536

KERNEL_SHMMAX=$((NR_HUGEPAGES * 2 * 1024 * 1024))

case "$DEPLOYMENT_PROFILE" in
    micro|minimal) NETLINK_MEM=67108864 ;;
    small)         NETLINK_MEM=134217728 ;;
    medium)        NETLINK_MEM=268435456 ;;
    large)         NETLINK_MEM=536870912 ;;
    extreme)       NETLINK_MEM=1073741824 ;;
esac

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
net.core.netdev_max_backlog=300000
net.core.netdev_budget=50000
net.core.netdev_budget_usecs=8000
net.core.somaxconn=65535
net.core.optmem_max=67108864
net.ipv4.tcp_max_syn_backlog=65535
net.ipv4.tcp_mem=67108864 134217728 268435456
net.ipv4.udp_mem=67108864 134217728 268435456
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864
net.ipv4.udp_rmem_min=16384
net.ipv4.udp_wmem_min=16384
net.ipv4.ip_local_port_range=1024 65535
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_syncookies=1
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
net.ipv6.conf.all.forwarding=1
net.ipv4.ip_forward=1
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv6.conf.all.accept_redirects=0
EOFNETLINK

cat > /etc/sysctl.d/82-vpp-performance.conf <<EOFPERF
kernel.sched_min_granularity_ns=10000000
kernel.sched_wakeup_granularity_ns=15000000
kernel.sched_migration_cost_ns=5000000
kernel.sched_autogroup_enabled=0
kernel.numa_balancing=0
vm.zone_reclaim_mode=0
vm.swappiness=10
vm.dirty_ratio=40
vm.dirty_background_ratio=10
vm.vfs_cache_pressure=50
EOFPERF

sysctl -p -f /etc/sysctl.d/80-vpp.conf >/dev/null 2>&1
sysctl -p -f /etc/sysctl.d/81-vpp-netlink.conf >/dev/null 2>&1
sysctl -p -f /etc/sysctl.d/82-vpp-performance.conf >/dev/null 2>&1

if [ "$DEPLOYMENT_PROFILE" = "large" ] || [ "$DEPLOYMENT_PROFILE" = "extreme" ]; then
    SCHEDULER_POLICY="fifo"
    SCHEDULER_PRIORITY=50
else
    SCHEDULER_POLICY=""
    SCHEDULER_PRIORITY=""
fi

case "$DEPLOYMENT_PROFILE" in
    micro|minimal) RX_DESC=1024; TX_DESC=1024 ;;
    small)         RX_DESC=2048; TX_DESC=2048 ;;
    medium)        RX_DESC=4096; TX_DESC=4096 ;;
    large|extreme) RX_DESC=4096; TX_DESC=4096 ;;
esac

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
    
    [ -n "$IFACE" ] && ip link set "$IFACE" down 2>/dev/null || true
    
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

cp "$TEMPLATE" "$CONF"

if [ $IS_VM -eq 1 ]; then
    sed -i '/interactive/a\  poll-sleep-usec 100' "$CONF"
fi

NUM_MBUFS=$((BUFFERS_PER_NUMA * NUMA_NODES * 2))
[ $NUM_MBUFS -lt 65536 ] && NUM_MBUFS=65536
[ $NUM_MBUFS -gt 1048576 ] && NUM_MBUFS=1048576

sed -i "s/^dpdk {.*/dpdk {\n  socket-mem $SOCKET_MEM_STR\n  num-mbufs $NUM_MBUFS\n  no-tx-checksum-offload/" "$CONF"

for PCI in $PCI_DEVICES; do
    nic_speed=${NIC_SPEEDS[$PCI]}
    nic_queues=${NIC_QUEUES[$PCI]}
    
    if [ $nic_speed -ge 100000 ]; then
        nic_rx_desc=8192
        nic_tx_desc=8192
        nic_rx_burst=64
        nic_tx_burst=64
    elif [ $nic_speed -ge 40000 ]; then
        nic_rx_desc=4096
        nic_tx_desc=4096
        nic_rx_burst=32
        nic_tx_burst=32
    elif [ $nic_speed -ge 10000 ]; then
        nic_rx_desc=$RX_DESC
        nic_tx_desc=$TX_DESC
        nic_rx_burst=32
        nic_tx_burst=32
    else
        nic_rx_desc=1024
        nic_tx_desc=1024
        nic_rx_burst=16
        nic_tx_burst=16
    fi
    
    [ $nic_queues -gt $((WORKER_CORES / 2)) ] && nic_queues=$((WORKER_CORES / 2))
    [ $nic_queues -lt 1 ] && nic_queues=1
    
    sed -i "/socket-mem/a\\
  dev $PCI {\\
    num-rx-queues $nic_queues\\
    num-tx-queues $nic_queues\\
    num-rx-desc $nic_rx_desc\\
    num-tx-desc $nic_tx_desc\\
  }" "$CONF"
done

sed -i "/^socksvr {/,/^}/ {
  /^}/a\\
\\
statseg {\\
  size ${STATSEG_SIZE}M\\
  page-size default-hugepage\\
  per-node-counters on\\
}
}" "$CONF"

sed -i "/^socksvr {/,/^}/ {
  /^}/a\\
\\
buffers {\\
  buffers-per-numa ${BUFFERS_PER_NUMA}\\
  default data-size 2048\\
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

CPU_SECTION="cpu {\\
  main-core $MAIN_CORE\\
  corelist-workers $WORKER_LIST"

[ -n "$SCHEDULER_POLICY" ] && CPU_SECTION="${CPU_SECTION}\\
  scheduler-policy $SCHEDULER_POLICY\\
  scheduler-priority $SCHEDULER_PRIORITY"

CPU_SECTION="${CPU_SECTION}\\
}"

sed -i "/^socksvr {/,/^}/ {
  /^}/a\\
\\
$CPU_SECTION
}" "$CONF"

if [ "$DEPLOYMENT_PROFILE" != "minimal" ] && [ "$DEPLOYMENT_PROFILE" != "micro" ]; then
    if [ "$DEPLOYMENT_PROFILE" = "large" ] || [ "$DEPLOYMENT_PROFILE" = "extreme" ]; then
        FIB_HEAP="2G"
        NAT_TRANSLATIONS=4194304
        SESSION_BUCKETS=100000
        SESSION_MEM="256M"
        ACL_HEAP="1G"
    else
        FIB_HEAP="512M"
        NAT_TRANSLATIONS=1048576
        SESSION_BUCKETS=20000
        SESSION_MEM="64M"
        ACL_HEAP="512M"
    fi
    
    sed -i "/^logging {/i\\
ip {\\
  heap-size $FIB_HEAP\\
}\\
\\
ip6 {\\
  heap-size $FIB_HEAP\\
}\\
\\
nat {\\
  endpoint-dependent\\
  max translations per thread $NAT_TRANSLATIONS\\
}\\
\\
session {\\
  evt_qs_memfd_seg\\
  event-queue-length 16384\\
  preallocated-sessions 4096\\
  v4-session-table-buckets $SESSION_BUCKETS\\
  v4-session-table-memory $SESSION_MEM\\
  v6-session-table-buckets $SESSION_BUCKETS\\
  v6-session-table-memory $SESSION_MEM\\
}\\
\\
acl-plugin {\\
  use tuple merge 1\\
  hash lookup heap size $ACL_HEAP\\
}\\
" "$CONF"
fi

if [ "$DEPLOYMENT_PROFILE" != "micro" ] && [ "$DEPLOYMENT_PROFILE" != "minimal" ]; then
    IRQ_TARGET_CORE=$MAIN_CORE
    
    IRQ_SCRIPT="/usr/local/bin/vpp-irq-affinity.sh"
    
    cat > "$IRQ_SCRIPT" <<'EOFIRQSCRIPT'
#!/bin/bash
TARGET_CORE=${1:-0}

for pci_dir in /sys/bus/pci/devices/*; do
    [ -d "$pci_dir" ] || continue
    pci=$(basename "$pci_dir")
    
    driver_link="$pci_dir/driver"
    [ -L "$driver_link" ] || continue
    driver=$(basename $(readlink "$driver_link"))
    
    [ "$driver" = "vfio-pci" ] || [ "$driver" = "uio_pci_generic" ] || continue
    
    bus_id=$(echo $pci | cut -d':' -f2-)
    irq_nums=$(grep "$bus_id" /proc/interrupts 2>/dev/null | awk -F: '{print $1}' | tr -d ' ')
    
    for irq in $irq_nums; do
        [ -n "$irq" ] && [ -d "/proc/irq/$irq" ] && {
            echo $TARGET_CORE > /proc/irq/$irq/smp_affinity_list 2>/dev/null
        }
    done
done
EOFIRQSCRIPT
    
    chmod +x "$IRQ_SCRIPT"
    "$IRQ_SCRIPT" $IRQ_TARGET_CORE
    
    cat > /etc/systemd/system/vpp-irq-affinity.service <<EOFIRQSVC
[Unit]
Description=VPP IRQ Affinity Tuning
After=network-pre.target
Before=vpp.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$IRQ_SCRIPT $IRQ_TARGET_CORE

[Install]
WantedBy=multi-user.target
EOFIRQSVC
    
    systemctl daemon-reload
    systemctl enable vpp-irq-affinity.service >/dev/null 2>&1
fi

REBOOT_REQUIRED=0

if [ "$DEPLOYMENT_PROFILE" = "large" ] || [ "$DEPLOYMENT_PROFILE" = "extreme" ]; then
    if [ $CPU_CORES -ge 8 ] && [ $IS_VM -eq 0 ]; then
        if [ $NUMA_NODES -gt 1 ]; then
            ISOLATE_RANGES=""
            for node in $(seq 0 $((NUMA_NODES-1))); do
                node_start=${NUMA_CPUS_START[$node]}
                node_end=${NUMA_CPUS_END[$node]}
                
                if [ $node -eq 0 ]; then
                    iso_start=$((node_start + 2))
                else
                    iso_start=$((node_start + 1))
                fi
                
                if [ $iso_start -lt $node_end ]; then
                    [ -n "$ISOLATE_RANGES" ] && ISOLATE_RANGES="${ISOLATE_RANGES},"
                    ISOLATE_RANGES="${ISOLATE_RANGES}${iso_start}-${node_end}"
                fi
            done
        else
            iso_start=2
            iso_end=$((CPU_CORES - 1))
            [ $iso_start -lt $iso_end ] && ISOLATE_RANGES="${iso_start}-${iso_end}"
        fi
        
        if [ -n "$ISOLATE_RANGES" ]; then
            if ! grep -q "isolcpus=" /etc/default/grub 2>/dev/null; then
                cp /etc/default/grub /etc/default/grub.backup.$(date +%Y%m%d%H%M%S)
                
                sed -i "s/^GRUB_CMDLINE_LINUX=\"/GRUB_CMDLINE_LINUX=\"isolcpus=${ISOLATE_RANGES} nohz_full=${ISOLATE_RANGES} rcu_nocbs=${ISOLATE_RANGES} /" /etc/default/grub
                
                update-grub >/dev/null 2>&1
                
                REBOOT_REQUIRED=1
                echo "CPU isolation configured: $ISOLATE_RANGES (reboot required)"
            fi
        fi
    fi
fi

ACTUAL_WORKERS=$(echo "$WORKER_LIST" | tr ',' '\n' | while read range; do
    if echo "$range" | grep -q '-'; then
        start=$(echo "$range" | cut -d'-' -f1)
        end=$(echo "$range" | cut -d'-' -f2)
        echo $((end - start + 1))
    else
        echo 1
    fi
done | awk '{sum+=$1} END {print sum}')

echo "VPP Configuration Summary"
echo "Profile: $DEPLOYMENT_PROFILE"
if [ $HT_ENABLED -eq 1 ]; then
    echo "CPU: $PHYSICAL_CORES physical ($LOGICAL_CORES logical), $NUMA_NODES NUMA, $CPU_SOCKETS socket(s)"
else
    echo "CPU: $CPU_CORES cores, $NUMA_NODES NUMA, $CPU_SOCKETS socket(s)"
fi
echo "Main: core $MAIN_CORE"
echo "Workers: $WORKER_LIST ($ACTUAL_WORKERS)"
echo "Memory: socket-mem $SOCKET_MEM_STR MB, heap ${HEAP_SIZE_MB}MB"
echo "Buffers: $BUFFERS_PER_NUMA per-numa, hugepages $NR_HUGEPAGES"
echo "NICs: $NIC_COUNT, bandwidth ${TOTAL_BANDWIDTH}Mbps"
[ -n "$SCHEDULER_POLICY" ] && echo "Scheduler: $SCHEDULER_POLICY"
[ $REBOOT_REQUIRED -eq 1 ] && echo "Note: Reboot required for CPU isolation"
echo "Done at $(date)"

exit 0
