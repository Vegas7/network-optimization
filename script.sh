#!/usr/bin/env bash

# ==============================================================================
# Linux TCP/IP & BBR 智能优化脚本
#
# 版本: 3.1 (针对代理转发深度优化)
#
# 用法:
#   bash script.sh               应用优化
#   bash script.sh --dry-run     只打印将要写入的配置，不做任何修改
#   bash script.sh restore       恢复最近一次备份的配置
#   bash script.sh uninstall     删除配置并把运行时参数恢复到首次安装前
#
# 可选环境变量:
#   RESERVED_PORTS="443,8443,20000-30000"  从本地临时端口范围中保留这些端口，
#                                          避免出站连接占用你的服务端口
# ==============================================================================

SCRIPT_VERSION="3.1"

set -euo pipefail

# --- 颜色定义 ---
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- 路径 ---
CONF_FILE="/etc/sysctl.d/99-bbr.conf"
MODULES_FILE="/etc/modules-load.d/network-optimization.conf"
STATE_DIR="/var/lib/network-optimization"
SNAPSHOT_FILE="$STATE_DIR/original.sysctl"

DRY_RUN=false
TMP_CONF=""
MANAGED_KEYS=()
SKIPPED_KEYS=()

info() { echo -e "${CYAN}>>> $*${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $*${NC}" >&2; }
die()  { echo -e "${RED}❌ $*${NC}" >&2; exit 1; }

cleanup() { [[ -n "$TMP_CONF" && -f "$TMP_CONF" ]] && rm -f -- "$TMP_CONF"; return 0; }
trap cleanup EXIT

require_root() {
    [[ $(id -u) -eq 0 ]] || die "错误: 必须 root 权限。"
}

# sysctl 键是否被当前内核/容器支持
key_supported() {
    [[ -e "/proc/sys/${1//.//}" ]]
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

# --- 系统信息检测 ---
get_system_info() {
    TOTAL_MEM=$(free -m | awk '/^Mem:/{print $2}')
    CPU_CORES=$(nproc)

    # 物理机上 systemd-detect-virt 输出 none 且返回 1，在 set -e 下会直接退出脚本
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        VIRT_TYPE=$(systemd-detect-virt 2>/dev/null || true)
        [[ -n "$VIRT_TYPE" ]] || VIRT_TYPE="unknown"
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
    modprobe tcp_bbr >/dev/null 2>&1 || true
    if sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
        BBR_OK=true
    else
        BBR_OK=false
        warn "内核不支持 BBR（或在容器中无权加载），将跳过拥塞控制设置。"
    fi
}

# --- 配置写入：不支持的键直接跳过，避免 sysctl 报错 ---
add_conf() {
    local key="$1" value="$2" comment="$3"
    if ! key_supported "$key"; then
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

# --- 核心优化逻辑：先写临时文件，全部成功后再原子替换 ---
generate_config() {
    info "生成网络优化配置 (${YELLOW}${VM_TIER}${CYAN})..."
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
    if [[ -n "${RESERVED_PORTS:-}" ]]; then
        add_conf "net.ipv4.ip_local_reserved_ports" "$RESERVED_PORTS" "保留给服务监听的端口，出站连接不会占用"
    fi
    add_conf "net.ipv4.tcp_max_tw_buckets" "$(raise_only net.ipv4.tcp_max_tw_buckets "$TW_BUCKETS")" "允许更多 TIME_WAIT socket 存在"

    # 5. TCP Keepalive (快速剔除死链，只对开启 SO_KEEPALIVE 的程序生效)
    add_conf "net.ipv4.tcp_keepalive_time" "300" "TCP保活时间 (5分钟)"
    add_conf "net.ipv4.tcp_keepalive_intvl" "30" "探测间隔"
    add_conf "net.ipv4.tcp_keepalive_probes" "3" "探测次数"

    # 6. 连接跟踪：只在 conntrack 已经被使用（iptables/nft NAT、端口跳跃等）时才设置
    if key_supported "net.netfilter.nf_conntrack_max"; then
        add_conf "net.netfilter.nf_conntrack_max" "$(raise_only net.netfilter.nf_conntrack_max "$CONNTRACK_MAX")" "最大连接跟踪数"
        add_conf "net.netfilter.nf_conntrack_tcp_timeout_established" "7200" "连接跟踪超时 (2小时)"
        CONNTRACK_USED=true
    else
        CONNTRACK_USED=false
    fi

    # 7. 其他系统级优化
    # 不再设置 fs.file-max：systemd 系统默认已是 LONG_MAX，写死 65536 反而是降级。
    # 代理进程真正受限的是每进程的 nofile（systemd 服务里的 LimitNOFILE）。
    add_conf "vm.swappiness" "10" "减少 Swap 使用"
    add_conf "net.ipv4.tcp_mtu_probing" "1" "开启 MTU 探测 (解决部分黑洞路由卡顿)"
    add_conf "net.ipv4.tcp_slow_start_after_idle" "0" "关闭空闲后的慢启动重置"
}

install_config() {
    # 首次安装前记录原始运行时值，供 uninstall 恢复
    if [[ ! -f "$SNAPSHOT_FILE" ]]; then
        mkdir -p "$STATE_DIR"
        local key
        for key in "${MANAGED_KEYS[@]}" fs.file-max; do
            key_supported "$key" && printf '%s=%s\n' "$key" "$(sysctl -n "$key" | tr -s '[:space:]' ' ')" >> "$SNAPSHOT_FILE"
        done
    fi

    manage_backups
    install -m 0644 "$TMP_CONF" "$CONF_FILE"

    # conntrack 参数在开机时需要模块先于 systemd-sysctl 加载，否则重启后不生效
    if $CONNTRACK_USED; then
        echo "nf_conntrack" > "$MODULES_FILE"
    else
        rm -f -- "$MODULES_FILE"
    fi
}

# 让 default_qdisc=fq 立即作用到当前出口网卡（否则要等重启）
refresh_qdisc() {
    command -v tc >/dev/null 2>&1 || { warn "未找到 tc，fq 需重启后对现有网卡生效。"; return 0; }
    local ifc root
    ifc=$(ip -o route show default 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}')
    [[ -n "$ifc" ]] || return 0
    root=$(tc qdisc show dev "$ifc" 2>/dev/null | awk '/ root /{print $2; exit}')
    case "$root" in
        fq) return 0 ;;
        mq)
            tc qdisc show dev "$ifc" | grep -qE '^qdisc (fq_codel|pfifo_fast|pfifo) ' || return 0
            tc qdisc replace dev "$ifc" root handle 1: mq 2>/dev/null || warn "$ifc 的 fq 需重启后生效。" ;;
        fq_codel|pfifo_fast|pfifo)
            tc qdisc replace dev "$ifc" root fq 2>/dev/null || warn "$ifc 的 fq 需重启后生效。" ;;
        *)
            if [[ -n "$root" && "$root" != "noqueue" ]]; then warn "$ifc 使用自定义队列 ($root)，未改动。"; fi ;;
    esac
    return 0
}

# --- 应用与逐项验证 ---
apply_and_verify() {
    info "应用配置..."
    local err
    err=$(sysctl --system 2>&1 >/dev/null || true)
    [[ -n "$err" ]] && warn "sysctl 报告了错误：" && echo "$err" | sed 's/^/    /' >&2

    refresh_qdisc

    local key want got bad=0 src
    while IFS= read -r line; do
        [[ "$line" =~ ^([a-z0-9_.-]+)\ =\ (.*)$ ]] || continue
        key="${BASH_REMATCH[1]}"; want="${BASH_REMATCH[2]}"
        got=$(sysctl -n "$key" 2>/dev/null | tr -s '[:space:]' ' ' | sed 's/ $//') || got="?"
        if [[ "$got" != "$want" ]]; then
            bad=1
            src=$(grep -lsE "^[[:space:]]*${key//./\\.}[[:space:]]*=" /etc/sysctl.conf /etc/sysctl.d/*.conf /run/sysctl.d/*.conf 2>/dev/null \
                  | grep -vF "$CONF_FILE" | tr '\n' ' ' || true)
            warn "$key 期望 $want，实际 $got${src:+（可能被覆盖：$src）}"
        fi
    done < "$CONF_FILE"

    ((${#SKIPPED_KEYS[@]})) && warn "当前内核/环境不支持，已跳过：${SKIPPED_KEYS[*]}"

    echo -e "${GREEN}✅ 优化完成!${NC}"
    echo -e "拥塞控制: ${YELLOW}$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)${NC} | 默认队列: ${YELLOW}$(sysctl -n net.core.default_qdisc 2>/dev/null)${NC}"
    ((bad)) || echo -e "全部参数已按预期生效。"
}

do_uninstall() {
    require_root
    rm -f -- "$CONF_FILE" "$MODULES_FILE"
    if [[ -f "$SNAPSHOT_FILE" ]]; then
        local line
        while IFS= read -r line; do
            sysctl -q -w "$line" >/dev/null 2>&1 || true
        done < "$SNAPSHOT_FILE"
        rm -f -- "$SNAPSHOT_FILE"
    fi
    sysctl --system >/dev/null 2>&1 || true
    echo -e "${GREEN}已删除优化配置并恢复原始参数。网卡队列等少数状态建议重启一次彻底复原。${NC}"
}

do_restore() {
    require_root
    local latest
    latest=$(find "$(dirname "$CONF_FILE")" -maxdepth 1 -name "$(basename "$CONF_FILE").bak_*" -printf '%T@ %p\n' \
             | sort -rn | head -n1 | cut -d' ' -f2-)
    [[ -n "$latest" ]] || die "没有可恢复的备份。"
    install -m 0644 "$latest" "$CONF_FILE"
    sysctl --system >/dev/null 2>&1 || true
    echo -e "${GREEN}已恢复备份：$latest${NC}"
}

# --- 主逻辑 ---
main() {
    case "${1:-}" in
        uninstall) do_uninstall; exit 0 ;;
        restore)   do_restore; exit 0 ;;
        --dry-run) DRY_RUN=true ;;
        "") ;;
        *) die "未知参数: $1（可用: --dry-run | restore | uninstall）" ;;
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
        exit 0
    fi

    install_config
    apply_and_verify
}

main "$@"