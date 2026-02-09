#!/bin/bash

# =================配置区域=================
DNS_SERVERS=("1.1.1.1" "8.8.8.8") # 加上114对比
DOMAINS=("youtube.com" "google.com" "reddit.com" "cloudflare.com" "intel.com") # 包含国内外
COUNT=5      # 测试次数 (为了快速出结果，改为5次)
INTERVAL=0.5 # 间隔 (秒)
# =========================================

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

install_deps() {
    echo -e "${GREEN}正在检查依赖...${NC}"
    local need_update=0
    local pkgs=""
    
    # 检查 dig (dnsutils)
    if ! command -v dig &> /dev/null; then pkgs="$pkgs dnsutils"; need_update=1; fi
    # 检查 curl
    if ! command -v curl &> /dev/null; then pkgs="$pkgs curl"; need_update=1; fi
    # 检查 bc
    if ! command -v bc &> /dev/null; then pkgs="$pkgs bc"; need_update=1; fi
    # 检查 gawk
    if ! command -v awk &> /dev/null; then pkgs="$pkgs gawk"; need_update=1; fi

    if [ $need_update -eq 1 ]; then
        echo -e "${RED}缺少依赖，正在尝试自动安装: $pkgs ...${NC}"
        if [ "$EUID" -ne 0 ]; then 
            sudo apt-get update && sudo apt-get install -y $pkgs
        else
            apt-get update && apt-get install -y $pkgs
        fi
        echo -e "${GREEN}依赖安装完成。${NC}"
    fi
}

calc_stats() {
    local data=("$@")
    if [ ${#data[@]} -eq 0 ]; then echo "N/A"; return; fi
    local min=${data[0]}; local max=${data[0]}; local sum=0; local count=${#data[@]}
    for i in "${data[@]}"; do
        if (( $(echo "$i < $min" | bc -l) )); then min=$i; fi
        if (( $(echo "$i > $max" | bc -l) )); then max=$i; fi
        sum=$(echo "$sum + $i" | bc -l)
    done
    local avg=$(echo "scale=1; $sum / $count" | bc -l)
    echo "${min}/${max}/${avg} ms"
}

main() {
    install_deps
    echo "========================================================"
    echo -e "DNS 延迟与 TCP 握手测试 | ${GREEN}开始${NC}"
    echo "========================================================"
    
    # 打印表头
    printf "%-18s | %-16s | %-22s | %-22s\n" "域名" "DNS服务器" "DNS解析(Min/Max/Avg)" "TCP握手(Min/Max/Avg)"
    echo "--------------------------------------------------------------------------------------"

    for domain in "${DOMAINS[@]}"; do
        for dns in "${DNS_SERVERS[@]}"; do
            dns_times=(); tcp_times=()
            
            # 为了进度条效果，不换行打印
            printf "%-18s | %-16s | 测试中..." "$domain" "$dns"

            for ((i=1; i<=COUNT; i++)); do
                # 1. DNS Query
                t_start=$(date +%s.%N)
                dig_out=$(dig @$dns $domain +short +time=1 2>&1)
                t_end=$(date +%s.%N)
                
                # 计算DNS耗时 (ms)
                if [ -z "$dig_out" ]; then
                    # 超时或失败
                    continue
                fi
                d_time=$(echo "($t_end - $t_start) * 1000" | bc -l)
                dns_times+=($d_time)

                # 获取第一个IP用于握手
                target_ip=$(echo "$dig_out" | head -n 1)
                
                # 2. TCP Handshake (如果IP合法)
                if [[ "$target_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                    c_time=$(curl -o /dev/null -s -w "%{time_connect}" --resolve "$domain:443:$target_ip" "https://$domain" --connect-timeout 2)
                    c_time_ms=$(echo "$c_time * 1000" | bc -l)
                    if (( $(echo "$c_time_ms > 0" | bc -l) )); then
                        tcp_times+=($c_time_ms)
                    fi
                fi
                sleep $INTERVAL
            done

            # 清除"测试中..."并打印结果
            # \r 回车不换行
            printf "\r%-18s | %-16s | %-22s | %-22s\n" "$domain" "$dns" "$(calc_stats "${dns_times[@]}")" "$(calc_stats "${tcp_times[@]}")"
        done
        echo "--------------------------------------------------------------------------------------"
    done
}

main