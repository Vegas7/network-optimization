#!/usr/bin/env bash

# ==============================================================================
# Linux TCP/IP & BBR 智能优化脚本
#
# 版本: 3.2 (针对代理转发深度优化)
#
# 用法:
#   bash script.sh               应用优化
#   bash script.sh --dry-run     只打印将要写入的配置，不做任何修改
#   bash script.sh restore       恢复最近一次备份的配置
#   bash script.sh uninstall     删除配置并把运行时参数恢复到首次安装前
#
# 可选环境变量:
#   RESERVED_PORTS="443,8443,20000-30000"  从本地临时端口范围中保留这些端口，
#                                          避免出站连接占用你的服务端口。
#                                          不设置则沿用上次的值；设为空串则取消保留
#   FIX_SYSCTL_CONF=1|0                    /etc/sysctl.conf 中有冲突参数时自动注释掉(1)
#                                          或只提示不修改(0)；不设置时交互询问
# ==============================================================================

SCRIPT_VERSION="3.2"

set -euo pipefail

# --- 颜色定义 ---
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- 路径 ---
CONF_FILE="/etc/sysctl.d/99-bbr.conf"
SYSCTL_CONF="/etc/sysctl.conf"
MODULES_FILE="/etc/modules-load.d/network-optimization.conf"
STATE_DIR="/var/lib/network-optimization"
SNAPSHOT_FILE="$STATE_DIR/original.sysctl"
CONFLICT_TAG="# [network-optimization] "

# 旧版本设置过、现在不再管理的参数的内核默认值，升级时直接恢复
declare -A LEGACY_DEFAULTS=(
    [net.ipv4.tcp_timestamps]=1
    [net.ipv4.tcp_syncookies]=1
    [net.netfilter.nf_conntrack_tcp_timeout_time_wait]=120
)

DRY_RUN=false
TMP_CONF=""
TMP_SNAP=""
MANAGED_KEYS=()
SKIPPED_KEYS=()
REBOOT_KEYS=()

info() { echo -e "${CYAN}>>> $*${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $*${NC}" >&2; }
die()  { echo -e "${RED}❌ $*${NC}" >&2; exit 1; }

cleanup() {
    [[ -n "$TMP_CONF" ]] && rm -f -- "$TMP_CONF"
    [[ -n "$TMP_SNAP" ]] && rm -f -- "$TMP_SNAP"
    return 0
}
trap cleanup EXIT

usage() {
    cat << 'EOF'
用法:
  bash script.sh               应用优化
  bash script.sh --dry-run     只打印将要写入的配置，不做任何修改
  bash script.sh restore       恢复最近一次备份的配置
  bash script.sh uninstall     删除配置并把运行时参数恢复到首次安装前

可选环境变量:
  RESERVED_PORTS="443,8443,20000-30000"  保留给服务监听的端口；不设置则沿用上次的值，设为空串则取消
  FIX_SYSCTL_CONF=1|0                    自动注释 /etc/sysctl.conf 中的冲突参数(1) 或只提示(0)
EOF
}

require_root() {
    [[ $(id -u) -eq 0 ]] || die "错误: 必须 root 权限。"
}

# sysctl 键是否被当前内核/容器支持
key_supported() {
    [[ -e "/proc/sys/${1//.//}" ]]
}

# 键存在且可写（容器内的 nf_conntrack_max、旧内核的 nf_conntrack_buckets 是只读的）
key_writable() {
    local p="/proc/sys/${1//.//}"
    [[ -e "$p" && $(stat -c %A -- "$p" 2>/dev/null) == ??w* ]]
}

# 读取运行时值，多个字段统一用单个空格分隔
get_val() {
    sysctl -n "$1" 2>/dev/null | tr -s '[:space:]' ' ' | sed 's/ $//'
}

# 直接写 /proc/sys，空值和带空格的值都能正确写入
write_key() {
    { printf '%s\n' "$2" > "/proc/sys/${1//.//}"; } 2>/dev/null
}

trim() {
    local s="$1"
    printf '%s' "${s%"${s##*[![:space:]]}"}"
}

# 对“上限类”参数只升不降：取当前值与目标值中较大的一个
raise_only() {
    local key="$1" target="$2" cur
    cur=$(sysctl -n "$key" 2>/dev/null) || { echo "$target"; return; }
    if [[ "$cur" =~ ^[0-9]+$ ]] && { (( ${#cur} > 18 )) || (( cur > target )); }; then
        echo "$cur"
    else
        echo "$target"
    fi
}

# --- 配置文件读取 ---
conf_keys() {
    sed -nE 's/^([a-z0-9_.-]+) = .*/\1/p' "$1"
}

conf_value() {
    sed -nE "s/^${2//./\\.} = //p" "$1" | tail -n1
}

conf_has_key() {
    grep -qE "^${2//./\\.} = " "$1"
}

# 旧配置里有、新配置里没有的键
dropped_keys() {
    conf_keys "$1" | grep -vxF -f <(conf_keys "$2") || true
}

# 只比较配置内容，忽略生成时间
same_config() {
    [[ "$(grep -v '^# 生成时间:' "$1")" == "$(grep -v '^# 生成时间:' "$2")" ]]
}

# 除本脚本外，还有哪些 sysctl 配置文件设置了这个键（符号链接去重）
sysctl_sources() {
    local f
    for f in "$SYSCTL_CONF" /etc/sysctl.d/*.conf /run/sysctl.d/*.conf \
             /usr/local/lib/sysctl.d/*.conf /usr/lib/sysctl.d/*.conf /lib/sysctl.d/*.conf; do
        [[ -f "$f" && "$f" != "$CONF_FILE" ]] || continue
        grep -qsE "^[[:space:]]*${1//./\\.}[[:space:]]*=" "$f" && readlink -f -- "$f"
    done | sort -u | tr '\n' ' ' | sed 's/ $//' || true
}

# --- 系统信息检测 ---
get_system_info() {
    TOTAL_MEM=$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo 2>/dev/null || true)
    [[ "$TOTAL_MEM" =~ ^[0-9]+$ ]] || die "无法从 /proc/meminfo 读取内存大小。"
    CPU_CORES=$(nproc 2>/dev/null || echo "?")

    # 物理机上 systemd-detect-virt 输出 none 且返回 1，在 set -e 下会直接退出脚本
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        VIRT_TYPE=$(systemd-detect-virt 2>/dev/null || true)
        [[ -n "$VIRT_TYPE" && "$VIRT_TYPE" != "none" ]] || VIRT_TYPE="Physical"
    elif grep -qi "hypervisor" /proc/cpuinfo; then
        VIRT_TYPE="KVM/VMware"
    else
        VIRT_TYPE="Physical/Unknown"
    fi

    info "系统信息检测："
    echo -e "内存大小   : ${YELLOW}${TOTAL_MEM}MB${NC}"
    echo -e "CPU核心数  : ${YELLOW}${CPU_CORES}${NC}"
    echo -e "虚拟化类型 : ${YELLOW}${VIRT_TYPE}${NC}"

    case "$VIRT_TYPE" in
        openvz|lxc|lxc-libvirt|docker|podman|systemd-nspawn|container-other)
            warn "检测到容器环境 ($VIRT_TYPE)：大部分 net.core / 拥塞控制参数由宿主机决定，可能无法生效。" ;;
    esac

    calculate_parameters
}

# --- 动态参数计算 (针对转发业务调整) ---
calculate_parameters() {
    if [ "$TOTAL_MEM" -le 512 ]; then
        VM_TIER="入门级(≤512MB)"
        BUF_MAX="16777216"    # 16MB
        SOMAXCONN="4096"
        CONNTRACK_MAX="32768"
        TW_BUCKETS="50000"
    elif [ "$TOTAL_MEM" -le 1024 ]; then
        VM_TIER="基础级(1GB)"
        BUF_MAX="33554432"    # 32MB
        SOMAXCONN="16384"
        CONNTRACK_MAX="65536"
        TW_BUCKETS="100000"
    elif [ "$TOTAL_MEM" -le 4096 ]; then
        VM_TIER="进阶级(2GB-4GB)"
        BUF_MAX="33554432"    # 32MB
        SOMAXCONN="16384"
        CONNTRACK_MAX="131072"
        TW_BUCKETS="200000"
    else
        VM_TIER="专业级(>4GB)"
        BUF_MAX="67108864"    # 64MB
        SOMAXCONN="32768"
        CONNTRACK_MAX="262144"
        TW_BUCKETS="300000"
    fi
}

# --- 预检查 ---
pre_flight_checks() {
    $DRY_RUN || require_root
    # 只加载 BBR；不再强行加载 nf_conntrack（没用到 NAT/防火墙状态跟踪的机器没必要加载）
    # dry-run 不加载模块，只检查模块是否存在
    $DRY_RUN || modprobe tcp_bbr >/dev/null 2>&1 || true
    if sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr \
        || { $DRY_RUN && modinfo tcp_bbr >/dev/null 2>&1; }; then
        BBR_OK=true
    else
        BBR_OK=false
        warn "内核不支持 BBR（或在容器中无权加载），将跳过拥塞控制设置。"
    fi
}

# --- 保留端口：校验并整理成内核输出的格式（排序、合并相邻区间），便于验证比对 ---
port_range() {
    if (( $2 > $1 )); then echo "$1-$2"; else echo "$1"; fi
}

normalize_ports() {
    local lo hi cl=-1 ch=-1 out=""
    while IFS=- read -r lo hi; do
        hi=${hi:-$lo}
        lo=$((10#$lo)); hi=$((10#$hi))
        (( lo >= 1 && hi <= 65535 && lo <= hi )) || return 1
        if (( cl < 0 )); then
            cl=$lo; ch=$hi
        elif (( lo <= ch + 1 )); then
            ch=$(( hi > ch ? hi : ch ))
        else
            out+="$(port_range "$cl" "$ch"),"
            cl=$lo; ch=$hi
        fi
    done < <(tr ',' '\n' <<< "$1" | sort -t- -k1,1n)
    echo "$out$(port_range "$cl" "$ch")"
}

# 未设置 RESERVED_PORTS 时沿用当前配置里的值，避免重跑脚本时悄悄丢掉
resolve_reserved_ports() {
    local ports=""
    if [[ -n "${RESERVED_PORTS+x}" ]]; then
        ports="$RESERVED_PORTS"
    elif [[ -f "$CONF_FILE" ]]; then
        ports=$(conf_value "$CONF_FILE" net.ipv4.ip_local_reserved_ports)
    fi
    ports="${ports//[[:space:]]/}"
    RESERVED_PORTS_NORM=""
    [[ -n "$ports" ]] || return 0
    [[ "$ports" =~ ^[0-9]{1,5}(-[0-9]{1,5})?(,[0-9]{1,5}(-[0-9]{1,5})?)*$ ]] \
        && RESERVED_PORTS_NORM=$(normalize_ports "$ports") \
        || die "RESERVED_PORTS 格式错误：$ports（示例：443,8443,20000-30000，端口范围 1-65535）"
}

# --- 配置写入：不支持或只读的键直接跳过，避免 sysctl 报错 ---
add_conf() {
    local key="$1" value="$2" comment="$3"
    if ! key_writable "$key"; then
        SKIPPED_KEYS+=("$key")
        return 0
    fi
    MANAGED_KEYS+=("$key")
    {
        echo "# $comment"
        echo "$key = $value"
        echo ""
    } >> "$TMP_CONF"
}

# --- 备份管理 ---
manage_backups() {
    if [ -f "$CONF_FILE" ]; then
        cp -- "$CONF_FILE" "$CONF_FILE.bak_$(date +%F_%H-%M-%S)"
        # 保留最近3个备份（备份名不以 .conf 结尾，不会被 sysctl --system 读取）
        find "$(dirname "$CONF_FILE")" -maxdepth 1 -name "$(basename "$CONF_FILE").bak_*" -printf '%T@ %p\n' \
            | sort -rn | tail -n +4 | cut -d' ' -f2- | xargs -r rm -f --
    fi
}

# --- 核心优化逻辑：先写临时文件，全部成功后再替换 ---
generate_config() {
    info "生成网络优化配置 (${YELLOW}${VM_TIER}${CYAN})..."
    resolve_reserved_ports
    TMP_CONF=$(mktemp "${TMPDIR:-/tmp}/network-optimization.XXXXXX")

    cat >> "$TMP_CONF" << EOF
# ==========================================================
# Linux Network Tuning (Proxy/Forwarding Optimized) v${SCRIPT_VERSION}
# 生成时间: $(date)
# 硬件环境: ${TOTAL_MEM}MB RAM, ${CPU_CORES} CPU
# ==========================================================

EOF

    # 1. BBR 与 队列算法
    add_conf "net.core.default_qdisc" "fq" "FQ 队列算法 (BBR 最佳拍档)"
    $BBR_OK && add_conf "net.ipv4.tcp_congestion_control" "bbr" "开启 BBR"

    # 2. 缓冲区 (TCP & UDP)。rmem_max/wmem_max 决定 QUIC/Hysteria 能申请到的 socket 缓冲上限
    add_conf "net.core.rmem_max" "$BUF_MAX" "系统最大接收缓存"
    add_conf "net.core.wmem_max" "$BUF_MAX" "系统最大发送缓存"
    add_conf "net.core.rmem_default" "262144" "默认接收缓存 (256k)"
    add_conf "net.core.wmem_default" "262144" "默认发送缓存 (256k)"
    add_conf "net.ipv4.tcp_rmem" "8192 262144 $BUF_MAX" "TCP读缓存 (min default max)"
    add_conf "net.ipv4.tcp_wmem" "8192 262144 $BUF_MAX" "TCP写缓存 (min default max)"
    add_conf "net.ipv4.udp_rmem_min" "16384" "UDP读缓存下限"
    add_conf "net.ipv4.udp_wmem_min" "16384" "UDP写缓存下限"

    # 3. 连接与队列上限（只升不降）
    add_conf "net.core.somaxconn" "$(raise_only net.core.somaxconn "$SOMAXCONN")" "最大监听队列"
    add_conf "net.core.netdev_max_backlog" "$(raise_only net.core.netdev_max_backlog "$SOMAXCONN")" "网卡积压队列"
    add_conf "net.ipv4.tcp_max_syn_backlog" "$(raise_only net.ipv4.tcp_max_syn_backlog "$SOMAXCONN")" "SYN半连接队列"
    add_conf "net.ipv4.tcp_notsent_lowat" "16384" "降低缓冲区未发送数据阈值 (降低延迟)"

    # 4. TIME_WAIT 与 端口复用 (代理服务器的关键)
    add_conf "net.ipv4.tcp_tw_reuse" "1" "开启 TIME_WAIT 复用 (出站连接)"
    add_conf "net.ipv4.tcp_fin_timeout" "30" "缩短 FIN_WAIT 时间"
    add_conf "net.ipv4.ip_local_port_range" "10000 65535" "扩大本地端口范围"
    if [[ -n "$RESERVED_PORTS_NORM" ]]; then
        add_conf "net.ipv4.ip_local_reserved_ports" "$RESERVED_PORTS_NORM" "保留给服务监听的端口，出站连接不会占用"
    fi
    add_conf "net.ipv4.tcp_max_tw_buckets" "$(raise_only net.ipv4.tcp_max_tw_buckets "$TW_BUCKETS")" "允许更多 TIME_WAIT socket 存在"

    # 5. TCP Keepalive (快速剔除死链，只对开启 SO_KEEPALIVE 的程序生效)
    add_conf "net.ipv4.tcp_keepalive_time" "300" "TCP保活时间 (5分钟)"
    add_conf "net.ipv4.tcp_keepalive_intvl" "30" "探测间隔"
    add_conf "net.ipv4.tcp_keepalive_probes" "3" "探测次数"

    # 6. 连接跟踪：只在 conntrack 已经被使用（iptables/nft NAT、端口跳跃等）时才设置
    if key_supported "net.netfilter.nf_conntrack_max"; then
        add_conf "net.netfilter.nf_conntrack_max" "$(raise_only net.netfilter.nf_conntrack_max "$CONNTRACK_MAX")" "最大连接跟踪数"
        # 只调大上限不调哈希表，查找链会变长；旧内核上该键只读，会自动跳过
        add_conf "net.netfilter.nf_conntrack_buckets" "$(raise_only net.netfilter.nf_conntrack_buckets "$((CONNTRACK_MAX / 4))")" "连接跟踪哈希桶数 (约为上限的 1/4)"
        add_conf "net.netfilter.nf_conntrack_tcp_timeout_established" "7200" "连接跟踪超时 (2小时)"
    fi

    # 7. 其他系统级优化
    # 不再设置 fs.file-max：systemd 系统默认已是 LONG_MAX，写死 65536 反而是降级。
    # 代理进程真正受限的是每进程的 nofile（systemd 服务里的 LimitNOFILE）。
    add_conf "vm.swappiness" "10" "减少 Swap 使用"
    add_conf "net.ipv4.tcp_mtu_probing" "1" "开启 MTU 探测 (解决部分黑洞路由卡顿)"
    add_conf "net.ipv4.tcp_slow_start_after_idle" "0" "关闭空闲后的慢启动重置"
}

# --- 原始值快照 ---
# 每次安装都补录快照里还没有的键；若该键已被旧配置设置过，原始值已无从得知，记为 #unknown
update_snapshot() {
    mkdir -p "$STATE_DIR"
    TMP_SNAP=$(mktemp "$STATE_DIR/.snapshot.XXXXXX")
    [[ -f "$SNAPSHOT_FILE" ]] && cat -- "$SNAPSHOT_FILE" > "$TMP_SNAP"
    local key
    for key in "${MANAGED_KEYS[@]}"; do
        grep -qE "^(${key//./\\.}=|#unknown ${key//./\\.}$)" "$TMP_SNAP" && continue
        if [[ -f "$CONF_FILE" ]] && conf_has_key "$CONF_FILE" "$key"; then
            echo "#unknown $key" >> "$TMP_SNAP"
        else
            printf '%s=%s\n' "$key" "$(get_val "$key")" >> "$TMP_SNAP"
        fi
    done
    chmod 0644 "$TMP_SNAP"
    mv -f -- "$TMP_SNAP" "$SNAPSHOT_FILE"
    TMP_SNAP=""
}

snapshot_get() {
    [[ -f "$SNAPSHOT_FILE" ]] || return 1
    local line
    line=$(grep -m1 -E "^${1//./\\.}=" "$SNAPSHOT_FILE") || return 1
    trim "${line#*=}"
}

# 不再写入配置的键：恢复为快照中的原始值（或已知的内核默认值），否则提示需重启
release_keys() {
    local key val
    for key in "$@"; do
        [[ "$key" == "fs.file-max" ]] && continue    # 由 fix_legacy_file_max 处理
        if val=$(snapshot_get "$key"); then
            write_key "$key" "$val" || REBOOT_KEYS+=("$key")
        elif [[ -n "${LEGACY_DEFAULTS[$key]:-}" ]]; then
            write_key "$key" "${LEGACY_DEFAULTS[$key]}" || REBOOT_KEYS+=("$key")
        else
            REBOOT_KEYS+=("$key")
        fi
    done
}

# 3.0 及更早版本把 fs.file-max 写死为 65536~524288。systemd 只在开机时把它提升到 LONG_MAX，
# 升级后不重启会一直停在旧值。没有其他配置文件管理它时，把它恢复为默认值。
fix_legacy_file_max() {
    local cur target
    cur=$(get_val fs.file-max) || return 0
    case "$cur" in 65536|131072|262144|524288) ;; *) return 0 ;; esac
    [[ -z "$(sysctl_sources fs.file-max)" ]] || return 0
    if [[ -d /run/systemd/system ]]; then
        target=$(getconf LONG_MAX 2>/dev/null || echo 9223372036854775807)
    else
        target=$(awk '/^MemTotal:/{print int($2/10)}' /proc/meminfo)
    fi
    (( ${#target} > 18 || target > cur )) || return 0
    if write_key fs.file-max "$target"; then
        info "已把旧版本写入的 fs.file-max=$cur 恢复为默认值 $target"
    fi
}

# conntrack 参数在开机时需要模块先于 systemd-sysctl 加载，否则重启后不生效
sync_modules_file() {
    if grep -q '^net\.netfilter\.' "$1"; then
        mkdir -p "$(dirname "$MODULES_FILE")"
        echo "nf_conntrack" > "$MODULES_FILE"
    else
        rm -f -- "$MODULES_FILE"
    fi
}

install_config() {
    update_snapshot

    if [[ -f "$CONF_FILE" ]] && same_config "$CONF_FILE" "$TMP_CONF"; then
        info "配置与现有文件一致，跳过写入和备份。"
    else
        local dropped=""
        [[ -f "$CONF_FILE" ]] && dropped=$(dropped_keys "$CONF_FILE" "$TMP_CONF")
        manage_backups
        # 先写同目录临时文件再 mv，保证替换是原子的（.new 不以 .conf 结尾，不会被读取）
        install -m 0644 "$TMP_CONF" "$CONF_FILE.new"
        mv -f -- "$CONF_FILE.new" "$CONF_FILE"
        # shellcheck disable=SC2086 # 键名不含空白，按单词拆分
        release_keys $dropped
    fi

    fix_legacy_file_max
    sync_modules_file "$CONF_FILE"
}

# --- /etc/sysctl.conf 冲突处理 ---
# sysctl --system 最后读取 /etc/sysctl.conf，Debian/Ubuntu 上它的软链接 99-sysctl.conf
# 也排在 99-bbr.conf 之后，所以那里残留的同名参数一定会覆盖本脚本
fix_sysctl_conf_conflicts() {
    [[ -f "$SYSCTL_CONF" ]] || return 0
    local key target ans conflicts=()
    for key in "${MANAGED_KEYS[@]}"; do
        grep -qE "^[[:space:]]*${key//./\\.}[[:space:]]*=" "$SYSCTL_CONF" && conflicts+=("$key")
    done
    ((${#conflicts[@]})) || return 0

    warn "$SYSCTL_CONF 中的以下参数会覆盖本脚本的设置：${conflicts[*]}"
    $DRY_RUN && return 0
    case "${FIX_SYSCTL_CONF:-}" in
        1) ;;
        0) return 0 ;;
        *)
            [[ -t 0 ]] || { warn "非交互运行，未修改。可用 FIX_SYSCTL_CONF=1 自动注释这些行。"; return 0; }
            read -r -p "是否注释掉这些行（会先备份，uninstall 时自动还原）？[Y/n] " ans || ans="n"
            [[ "$ans" =~ ^([Yy]|[Yy][Ee][Ss])?$ ]] || return 0 ;;
    esac

    target=$(readlink -f -- "$SYSCTL_CONF")
    cp -- "$target" "$target.bak_network-optimization_$(date +%F_%H-%M-%S)"
    for key in "${conflicts[@]}"; do
        sed -i -E "s|^([[:space:]]*${key//./\\.}[[:space:]]*=)|${CONFLICT_TAG}\1|" "$target"
    done
    info "已注释 $SYSCTL_CONF 中的冲突参数。"
}

restore_sysctl_conf_conflicts() {
    [[ -f "$SYSCTL_CONF" ]] || return 0
    local target
    target=$(readlink -f -- "$SYSCTL_CONF")
    grep -qF "$CONFLICT_TAG" "$target" || return 0
    sed -i "s|^# \[network-optimization\] ||" "$target"
    info "已还原 $SYSCTL_CONF 中被注释的参数。"
}

# 让 default_qdisc=fq 立即作用到当前出口网卡（否则要等重启）
refresh_qdisc_dev() {
    local ifc="$1" root
    root=$(tc qdisc show dev "$ifc" 2>/dev/null | awk '/ root /{print $2; exit}' || true)
    case "$root" in
        fq) return 0 ;;
        mq)
            tc qdisc show dev "$ifc" 2>/dev/null | grep -qE '^qdisc (fq_codel|pfifo_fast|pfifo) ' || return 0
            tc qdisc replace dev "$ifc" root handle 1: mq 2>/dev/null || warn "$ifc 的 fq 需重启后生效。" ;;
        fq_codel|pfifo_fast|pfifo)
            tc qdisc replace dev "$ifc" root fq 2>/dev/null || warn "$ifc 的 fq 需重启后生效。" ;;
        *)
            if [[ -n "$root" && "$root" != "noqueue" ]]; then warn "$ifc 使用自定义队列 ($root)，未改动。"; fi ;;
    esac
    return 0
}

refresh_qdisc() {
    command -v tc >/dev/null 2>&1 || { warn "未找到 tc，fq 需重启后对现有网卡生效。"; return 0; }
    local ifc ifaces
    # IPv4 和 IPv6 默认路由的出口网卡都处理（纯 IPv6 机器只有后者）
    ifaces=$( { ip -o -4 route show default; ip -o -6 route show default; } 2>/dev/null \
              | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); break}}' | sort -u || true)
    for ifc in $ifaces; do
        refresh_qdisc_dev "$ifc"
    done
    return 0
}

# --- 应用与逐项验证 ---
apply_and_verify() {
    info "应用配置..."
    local err
    err=$(sysctl --system 2>&1 >/dev/null || true)
    [[ -n "$err" ]] && warn "sysctl 报告了错误：" && echo "$err" | sed 's/^/    /' >&2

    refresh_qdisc

    local line key want got bad=0 src
    while IFS= read -r line; do
        [[ "$line" =~ ^([a-z0-9_.-]+)\ =\ (.*)$ ]] || continue
        key="${BASH_REMATCH[1]}"; want="${BASH_REMATCH[2]}"
        got=$(get_val "$key") || got="?"
        if [[ "$got" != "$want" ]]; then
            bad=1
            src=$(sysctl_sources "$key")
            warn "$key 期望 $want，实际 $got${src:+（可能被覆盖：$src）}"
        fi
    done < "$CONF_FILE"

    ((${#SKIPPED_KEYS[@]})) && warn "当前内核/环境不支持或只读，已跳过：${SKIPPED_KEYS[*]}"
    ((${#REBOOT_KEYS[@]})) && warn "以下参数已不再由本脚本管理，但原始值未知，重启后才会回到系统默认值：${REBOOT_KEYS[*]}"

    echo -e "${GREEN}✅ 优化完成!${NC}"
    echo -e "拥塞控制: ${YELLOW}$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)${NC} | 默认队列: ${YELLOW}$(sysctl -n net.core.default_qdisc 2>/dev/null)${NC}"
    ((bad)) || echo -e "全部参数已按预期生效。"
}

do_uninstall() {
    require_root
    local line key old_keys=""
    [[ -f "$CONF_FILE" ]] && old_keys=$(conf_keys "$CONF_FILE")
    rm -f -- "$CONF_FILE" "$CONF_FILE.new" "$MODULES_FILE"
    restore_sysctl_conf_conflicts

    # 快照里没有原始值的键（旧版本安装的）：已知默认值的直接恢复，其余只能靠重启
    for key in $old_keys; do
        [[ "$key" == "fs.file-max" ]] && continue
        snapshot_get "$key" >/dev/null && continue
        if [[ -n "${LEGACY_DEFAULTS[$key]:-}" ]]; then
            write_key "$key" "${LEGACY_DEFAULTS[$key]}" || true
        else
            REBOOT_KEYS+=("$key")
        fi
    done

    if [[ -f "$SNAPSHOT_FILE" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" || "$line" == "#"* ]] && continue
            key="${line%%=*}"
            # 3.1 的快照会记录 fs.file-max，可能是 3.0 写入的降级值，不能恢复它
            [[ "$key" == "fs.file-max" ]] && continue
            write_key "$key" "$(trim "${line#*=}")" || warn "无法恢复 $key"
        done < "$SNAPSHOT_FILE"
        rm -f -- "$SNAPSHOT_FILE"
        rmdir -- "$STATE_DIR" 2>/dev/null || true
    fi
    fix_legacy_file_max
    sysctl --system >/dev/null 2>&1 || true

    if ((${#REBOOT_KEYS[@]})); then
        echo -e "${GREEN}已删除优化配置。${NC}"
        warn "以下参数由旧版本脚本设置，原始值未知，重启后才会回到系统默认值：${REBOOT_KEYS[*]}"
    else
        echo -e "${GREEN}已删除优化配置并恢复原始参数。网卡队列等少数状态建议重启一次彻底复原。${NC}"
    fi
}

do_restore() {
    require_root
    local latest dropped=""
    latest=$(find "$(dirname "$CONF_FILE")" -maxdepth 1 -name "$(basename "$CONF_FILE").bak_*" -printf '%T@ %p\n' \
             | sort -rn | head -n1 | cut -d' ' -f2- || true)
    [[ -n "$latest" ]] || die "没有可恢复的备份。"
    [[ -f "$CONF_FILE" ]] && dropped=$(dropped_keys "$CONF_FILE" "$latest")
    install -m 0644 "$latest" "$CONF_FILE.new"
    mv -f -- "$CONF_FILE.new" "$CONF_FILE"
    # shellcheck disable=SC2086
    release_keys $dropped
    sync_modules_file "$CONF_FILE"
    sysctl --system >/dev/null 2>&1 || true
    echo -e "${GREEN}已恢复备份：$latest${NC}"
    ((${#REBOOT_KEYS[@]})) && warn "以下参数原始值未知，重启后才会回到系统默认值：${REBOOT_KEYS[*]}"
    return 0
}

# --- 主逻辑 ---
main() {
    (( $# <= 1 )) || die "参数过多（可用: --dry-run | restore | uninstall | --help）"
    case "${1:-}" in
        uninstall) do_uninstall; exit 0 ;;
        restore)   do_restore; exit 0 ;;
        --dry-run) DRY_RUN=true ;;
        -h|--help) usage; exit 0 ;;
        "") ;;
        *) die "未知参数: $1（可用: --dry-run | restore | uninstall | --help）" ;;
    esac

    echo -e "${CYAN}======================================================${NC}"
    echo -e "${CYAN}   Linux Network Optimizer (Proxy Edition) v${SCRIPT_VERSION}   ${NC}"
    echo -e "${CYAN}======================================================${NC}"

    pre_flight_checks
    get_system_info
    generate_config

    if $DRY_RUN; then
        info "dry-run：以下配置不会被写入"
        cat "$TMP_CONF"
        fix_sysctl_conf_conflicts
        exit 0
    fi

    install_config
    fix_sysctl_conf_conflicts
    apply_and_verify
}

main "$@"
