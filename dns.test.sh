#!/bin/bash

# =================配置区域=================
# 待测试的 DNS 服务器
DNS_SERVERS=("1.1.1.1" "8.8.8.8")

# 待测试的域名
DOMAINS=("youtube.com" "googlevideo.com" "google.com" "reddit.com" "cloudflare.com")

# 每个域名测试次数
COUNT=10

# 每次测试间隔 (秒)
INTERVAL=1
# =========================================

# 检查依赖
check_dependencies() {
    local missing=0
    for cmd in dig curl bc awk; do
        if ! command -v $cmd &> /dev/null; then
            echo "错误: 未找到命令 '$cmd'。"
            missing=1
        fi
    done
    if [ $missing -eq 1 ]; then
        echo "请先安装依赖: sudo apt-get update && sudo apt-get install -y dnsutils curl bc gawk"
        exit 1
    fi
}

# 计算统计数据 (Min/Max/Avg)
calc_stats() {
    # 输入: 数组字符串
    local data=("$@")
    if [ ${#data[@]} -eq 0 ]; then
        echo "N/A / N/A / N/A"
        return
    fi
    
    local min=${data[0]}
    local max=${data[0]}
    local sum=0
    local count=${#data[@]}

    for i in "${data[@]}"; do
        if (( $(echo "$i < $min" | bc -l) )); then min=$i; fi
        if (( $(echo "$i > $max" | bc -l) )); then max=$i; fi
        sum=$(echo "$sum + $i" | bc -l)
    done

    local avg=$(echo "scale=2; $sum / $count" | bc -l)
    echo "${min}ms / ${max}ms / ${avg}ms"
}

# 主程序
main() {
    check_dependencies
    
    echo "========================================================"
    echo "DNS & 连接质量测试脚本"
    echo "服务器: ${DNS_SERVERS[*]}"
    echo "域名: ${DOMAINS[*]}"
    echo "每项测试 $COUNT 次，间隔 ${INTERVAL}s"
    echo "========================================================"

    for dns in "${DNS_SERVERS[@]}"; do
        echo ""
        echo "正在测试 DNS 服务器: $dns ..."
        printf "%-20s | %-25s | %-25s | %-25s\n" "域名" "DNS解析(Min/Max/Avg)" "TCP握手(Min/Max/Avg)" "总耗时(Min/Max/Avg)"
        echo "----------------------------------------------------------------------------------------------------------------"

        for domain in "${DOMAINS[@]}"; do
            # 初始化数组
            dns_times=()
            tcp_times=()
            total_times=()

            for ((i=1; i<=COUNT; i++)); do
                # 1. DNS 解析 (使用 dig)
                # 抓取输出以同时获取 IP 和 时间
                dig_out=$(dig @$dns $domain +stats +noall +answer +comments 2>&1)
                
                # 提取解析耗时 (msec)
                d_time=$(echo "$dig_out" | grep "Query time:" | awk '{print $4}')
                
                # 提取解析到的第一个 A 记录 IP
                target_ip=$(echo "$dig_out" | awk '/IN[[:space:]]+A/ {print $5; exit}')

                # 如果没有解析到 IP (例如 googlevideo.com 根域名可能无A记录)，跳过连接测试
                if [ -z "$target_ip" ] || [ -z "$d_time" ]; then
                     # 记录失败或仅记录 DNS 时间
                     if [ ! -z "$d_time" ]; then dns_times+=($d_time); fi
                else
                    dns_times+=($d_time)

                    # 2. TCP 握手 (使用 curl 强制解析到该 IP)
                    # time_connect: TCP 握手耗时 (秒 -> 毫秒)
                    # 仅测试端口 443 (HTTPS)
                    curl_out=$(curl -o /dev/null -s -w "%{time_connect}" --resolve "$domain:443:$target_ip" "https://$domain" --connect-timeout 3)
                    
                    # 转换为毫秒
                    c_time=$(echo "$curl_out * 1000" | bc -l)
                    
                    # 只有当连接成功 (大于0) 才记录
                    if (( $(echo "$c_time > 0" | bc -l) )); then
                        tcp_times+=($c_time)
                        # 总耗时 = DNS耗时 + TCP握手
                        t_time=$(echo "$d_time + $c_time" | bc -l)
                        total_times+=($t_time)
                    fi
                fi
                
                sleep $INTERVAL
            done

            # 计算统计结果
            dns_res=$(calc_stats "${dns_times[@]}")
            tcp_res=$(calc_stats "${tcp_times[@]}")
            total_res=$(calc_stats "${total_times[@]}")

            printf "%-20s | %-25s | %-25s | %-25s\n" "$domain" "$dns_res" "$tcp_res" "$total_res"
        done
    done
    echo ""
    echo "测试完成。"
}

main