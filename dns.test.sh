#!/bin/bash
# ================================================================
# DNS & TCP Handshake Benchmark Tool (Menu Enhanced Version)
# ================================================================

export LC_ALL=C

# ================= 默认配置 =================
COUNT=10           # 测试次数 (建议10-20次以获取准确抖动)
INTERVAL=1         # 每次请求间隔
TIMEOUT=2          # 超时时间

# 内置 DNS 列表
DEFAULT_DNS_SERVERS=("1.1.1.1" "8.8.8.8")

# 内置 域名 列表
DEFAULT_DOMAINS=("cp.cloudflare.com" "www.gstatic.com" "www.youtube.com" "store.steampowered.com" "www.netflix.com" "play.max.com" "www.disneyplus.com")
# ===========================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# 全局变量存储最终选择
FINAL_DNS_LIST=()
FINAL_DOMAIN_LIST=()

# 检查依赖
check_env() {
    local pkgs=""
    if ! command -v dig &> /dev/null; then pkgs="$pkgs dnsutils"; fi
    if ! command -v curl &> /dev/null; then pkgs="$pkgs curl"; fi
    if ! command -v bc &> /dev/null; then pkgs="$pkgs bc"; fi
    if ! command -v awk &> /dev/null; then pkgs="$pkgs gawk"; fi

    if [ ! -z "$pkgs" ]; then
        echo -e "${YELLOW}正在安装必要依赖: $pkgs ...${NC}"
        if [ "$EUID" -ne 0 ]; then 
            sudo apt-get update -qq && sudo apt-get install -y -qq $pkgs
        else 
            apt-get update -qq && apt-get install -y -qq $pkgs
        fi
    fi
}

# 获取系统 DNS
get_system_dns() {
    local sys_dns=()
    # 尝试从 resolvectl 获取 (Systemd systems)
    if command -v resolvectl &> /dev/null; then
        local resolve_out
        resolve_out=$(resolvectl status | grep 'DNS Servers' | awk '{for(i=3;i<=NF;i++) print $i}')
        if [ ! -z "$resolve_out" ]; then
            sys_dns+=($resolve_out)
        fi
    fi

    # 尝试从 /etc/resolv.conf 获取 (通用)
    if [ ${#sys_dns[@]} -eq 0 ] && [ -f /etc/resolv.conf ]; then
        local conf_out
        conf_out=$(grep -v '^#' /etc/resolv.conf | grep nameserver | awk '{print $2}')
        sys_dns+=($conf_out)
    fi
    
    # 过滤掉 IPv6 (本脚本主要测试 IPv4)
    local ipv4_dns=()
    for ip in "${sys_dns[@]}"; do
        if [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            ipv4_dns+=($ip)
        fi
    done
    
    echo "${ipv4_dns[@]}"
}

# 数组去重
deduplicate_array() {
    echo "$@" | tr ' ' '\n' | sort -u | tr '\n' ' '
}

# 计算统计数据 (平均值 + 标准差/抖动)
calc_stats_advanced() {
    local data=("$@")
    if [ ${#data[@]} -eq 0 ]; then echo "Timeout/Fail"; return; fi
    
    echo "${data[@]}" | awk '{
        sum=0; sumsq=0; min=$1; max=$1;
        for(i=1;i<=NF;i++) {
            sum+=$i; 
            sumsq+=$i*$i;
            if($i<min) min=$i;
            if($i>max) max=$i;
        }
        if (NF > 0) {
            avg = sum/NF;
            if(NF > 1) {
                variance = (sumsq - (sum*sum)/NF) / (NF-1);
                if(variance < 0) variance = 0;
                stddev = sqrt(variance);
            } else {
                stddev = 0;
            }
            printf "Avg:%.1f ms | Jitter:%.1f", avg, stddev
        } else {
            printf "Error"
        }
    }'
}

# 核心测试循环
run_benchmark() {
    clear
    echo -e "========================================================================"
    echo -e " 开始测试 (Count: $COUNT | Interval: ${INTERVAL}s)"
    echo -e " ${CYAN}Jitter (抖动)${NC}: 越低越稳定。${RED}DNS Res${NC}: 解析耗时。${GREEN}TCP Conn${NC}: 建连耗时。"
    echo -e "========================================================================"
    
    printf "%-20s | %-16s | %-30s | %-30s\n" "Domain" "DNS Server" "DNS Resolution" "TCP Connect"
    echo "---------------------------------------------------------------------------------------------------------"

    for domain in "${FINAL_DOMAIN_LIST[@]}"; do
        for dns in "${FINAL_DNS_LIST[@]}"; do
            # 跳过空值
            [[ -z "$dns" ]] && continue
            
            dns_times=()
            tcp_times=()

            # 打印当前正在进行的任务（不换行）
            printf "%-20s | %-16s | Collecting samples..." "${domain:0:19}" "$dns"

            for ((i=1; i<=COUNT; i++)); do
                # 1. 测试 DNS 解析时间
                t_start=$(date +%s.%N)
                # dig 参数: +time=超时秒数 +tries=重试次数 +short只输出IP
                dig_out=$(dig @$dns $domain +short +time=$TIMEOUT +tries=1 2>/dev/null)
                t_end=$(date +%s.%N)
                
                # 检查 dig 是否成功
                if [ ! -z "$dig_out" ]; then
                    # 提取第一个看起来像 IP 的结果 (排除 CNAME 等)
                    target_ip=$(echo "$dig_out" | grep -E '^[0-9.]+$' | head -n 1)

                    if [ ! -z "$target_ip" ]; then
                        d_time=$(echo "($t_end - $t_start) * 1000" | bc -l)
                        dns_times+=($d_time)

                        # 2. 测试 TCP 握手时间 (基于解析出的 IP)
                        # 使用 --resolve 强制 curl 使用刚才解析到的 IP，模拟真实连接过程但排除二次解析干扰
                        c_time=$(curl -4 -o /dev/null -s -w "%{time_connect}" --resolve "$domain:443:$target_ip" "https://$domain" --connect-timeout $TIMEOUT)
                        
                        # 检查 curl 返回是否有效
                        if [ ! -z "$c_time" ]; then
                            c_time_ms=$(echo "$c_time * 1000" | bc -l)
                            # 简单的去噪，排除异常的0值
                            if (( $(echo "$c_time_ms > 0" | bc -l) )); then 
                                tcp_times+=($c_time_ms)
                            fi
                        fi
                    fi
                fi
                sleep $INTERVAL
            done

            d_res=$(calc_stats_advanced "${dns_times[@]}")
            t_res=$(calc_stats_advanced "${tcp_times[@]}")
            
            # 清除 "Collecting samples..." 并打印最终结果
            # \r 回到行首
            printf "\r%-20s | %-16s | %-30s | %-30s\n" "${domain:0:19}" "$dns" "$d_res" "$t_res"
        done
        echo "---------------------------------------------------------------------------------------------------------"
    done
    echo -e "\n${GREEN}测试完成。${NC}"
}

# 显示配置并确认
confirm_config() {
    while true; do
        clear
        echo -e "${CYAN}=== 配置确认 ===${NC}"
        echo -e "${YELLOW}待测 DNS 服务器:${NC}"
        for d in "${FINAL_DNS_LIST[@]}"; do echo -n "[$d] "; done
        echo -e "\n"
        echo -e "${YELLOW}待测 域名:${NC}"
        for d in "${FINAL_DOMAIN_LIST[@]}"; do echo -n "[$d] "; done
        echo -e "\n"
        
        echo -e "--------------------------------"
        read -p "开始进行测试? (y/n/b[回退]): " confirm
        case $confirm in
            [Yy]* ) run_benchmark; exit 0 ;;
            [Nn]* ) exit 0 ;;
            [Bb]* ) return 1 ;; # 返回 1 表示回退
            * ) echo "请输入 y, n 或 b"; sleep 1 ;;
        esac
    done
}

# 菜单逻辑
show_menu() {
    check_env
    
    while true; do
        clear
        echo -e "${CYAN}DNS 深度质量分析工具${NC}"
        echo "=============================="
        
        # --- 第一层：DNS 选择 ---
        echo -e "${GREEN}[1] 配置 DNS 服务器${NC}"
        echo "1. 系统DNS + 脚本内置DNS (自动去重)"
        echo "2. 仅使用脚本内置DNS"
        echo "3. 自定义 DNS (手动输入)"
        read -p "请选择 (1-3): " dns_choice

        local temp_dns_list=()
        case $dns_choice in
            1)
                sys_dns=$(get_system_dns)
                echo "检测到系统 DNS: $sys_dns"
                # 合并并去重
                combined_str=$(deduplicate_array ${DEFAULT_DNS_SERVERS[@]} $sys_dns)
                temp_dns_list=($combined_str)
                ;;
            2)
                temp_dns_list=("${DEFAULT_DNS_SERVERS[@]}")
                ;;
            3)
                echo -e "\n请输入DNS IP，用逗号分隔 (例如: 1.1.1.1,8.8.8.8):"
                read -r custom_dns_input
                # 将逗号替换为空格
                IFS=',' read -r -a temp_dns_list <<< "$custom_dns_input"
                ;;
            *)
                echo "无效输入"
                sleep 1
                continue
                ;;
        esac

        # --- 第二层：域名选择 ---
        echo -e "\n${GREEN}[2] 配置 目标域名${NC}"
        echo "1. 使用脚本内置域名"
        echo "2. 自定义域名 (手动输入)"
        read -p "请选择 (1-2): " domain_choice

        local temp_domain_list=()
        case $domain_choice in
            1)
                temp_domain_list=("${DEFAULT_DOMAINS[@]}")
                ;;
            2)
                echo -e "\n请输入域名，用逗号分隔 (例如: google.com,github.com):"
                read -r custom_domain_input
                IFS=',' read -r -a temp_domain_list <<< "$custom_domain_input"
                ;;
            *)
                echo "无效输入"
                sleep 1
                continue
                ;;
        esac

        # 设置全局变量
        FINAL_DNS_LIST=("${temp_dns_list[@]}")
        FINAL_DOMAIN_LIST=("${temp_domain_list[@]}")

        # --- 确认配置 ---
        confirm_config
        # 如果 confirm_config 返回 1 (用户选择了回退)，则循环会继续，回到菜单顶部
        if [ $? -eq 0 ]; then
            break
        fi
    done
}

# 入口
show_menu