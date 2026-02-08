#!/bin/bash
# 保存为 dns_test.sh

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

echo -e "${GREEN}--- DNS 优选测试脚本 (Google & Cloudflare) ---${PLAIN}"

# 检查并安装 dig (dnsutils)
if ! command -v dig &> /dev/null; then
    echo -e "${YELLOW}正在安装依赖 dnsutils...${PLAIN}"
    if [ -f /etc/debian_version ]; then
        apt-get update && apt-get install -y dnsutils
    elif [ -f /etc/redhat-release ]; then
        yum install -y bind-utils
    fi
fi

# 定义要测试的 DNS
targets=("1.1.1.1" "8.8.8.8" "9.9.9.9" "208.67.222.222")
check_domain="www.google.com"

echo -e "测试目标域名: ${YELLOW}$check_domain${PLAIN}"
echo -e "------------------------------------------------"

for dns in "${targets[@]}"; do
    echo -e "正在测试 DNS: ${GREEN}$dns${PLAIN}"
    
    # 1. 测试解析耗时 (Query time)
    lookup_time=$(dig @$dns $check_domain +stats +tries=1 +time=2 | grep "Query time" | awk '{print $4}')
    
    if [ -z "$lookup_time" ]; then
        echo -e "  -> ${RED}解析超时或失败${PLAIN}"
        continue
    fi
    
    # 2. 获取解析结果 IP (用于判断是否绕路)
    resolved_ip=$(dig @$dns +short $check_domain | head -1)

    # 3. 测试 TCP 连接握手 (更真实反映延迟)
    # 使用 curl 指定解析 IP 来测试握手时间
    tcp_time=$(curl -w "%{time_connect}" -o /dev/null -s --resolve $check_domain:443:$resolved_ip https://$check_domain)
    
    # 换算成 ms
    tcp_time_ms=$(echo "$tcp_time * 1000" | bc 2>/dev/null || echo "N/A")

    echo -e "  -> 解析耗时: ${YELLOW}${lookup_time} msec${PLAIN}"
    echo -e "  -> 解析结果: ${GREEN}${resolved_ip}${PLAIN}"
    echo -e "  -> TCP握手:  ${GREEN}${tcp_time_ms} ms${PLAIN}"
    echo -e "------------------------------------------------"
done