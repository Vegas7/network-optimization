#!/usr/bin/env bash
# =============================================================
# bt-block.sh —— 在落地 VPS 上拦截 BT / DHT / Tracker 出站流量
# 原理：iptables string 匹配，挂在 OUTPUT 链（代理服务端进程发出的连接都经过这里）
# 适用：Snell / ss-rust / sing-box 等任意代理服务端
#
# 用法：
#   bash bt-block.sh             安装（默认）
#   bash bt-block.sh install     安装并开机自启
#   bash bt-block.sh uninstall   卸载并清除规则
#   bash bt-block.sh status      查看规则与拦截计数
# 安装后也可以直接用命令：bt-block {apply|remove|status}
# =============================================================

BIN="/usr/local/sbin/bt-block"
UNIT="/etc/systemd/system/bt-block.service"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

# ---------------- 核心函数（会被写入 /usr/local/sbin/bt-block） ----------------

apply_rules() {
  local T s ok=0
  for T in iptables ip6tables; do
    command -v "$T" >/dev/null 2>&1 || continue
    "$T" -w -L -n >/dev/null 2>&1 || { echo "[$T] 不可用，跳过"; continue; }
    "$T" -w -N BT_BLOCK 2>/dev/null
    "$T" -w -F BT_BLOCK
    # 本机回环流量不处理
    "$T" -w -A BT_BLOCK -o lo -j RETURN
    # BT 握手（未加密时）
    "$T" -w -A BT_BLOCK -m string --algo bm --string "BitTorrent protocol" -j DROP || { echo "[$T] 不支持 string 匹配（缺少 xt_string 模块）"; continue; }
    # DHT 查询
    for s in get_peers announce_peer find_node info_hash; do
      "$T" -w -A BT_BLOCK -m string --algo bm --string "$s" -j DROP
    done
    # HTTP tracker 上报
    "$T" -w -A BT_BLOCK -m string --algo bm --string "peer_id=" -j DROP
    # UDP tracker 连接请求的固定协议标识 0x41727101980
    "$T" -w -A BT_BLOCK -p udp -m string --algo bm --hex-string "|0000041727101980|" -j DROP
    # 挂到 OUTPUT 链最前面（已存在则不重复添加）
    "$T" -w -C OUTPUT -j BT_BLOCK 2>/dev/null || "$T" -w -I OUTPUT 1 -j BT_BLOCK
    echo "[$T] 规则已应用"
    ok=1
  done
  [ "$ok" = 1 ]
}

remove_rules() {
  local T
  for T in iptables ip6tables; do
    command -v "$T" >/dev/null 2>&1 || continue
    while "$T" -w -D OUTPUT -j BT_BLOCK 2>/dev/null; do :; done
    "$T" -w -F BT_BLOCK 2>/dev/null
    "$T" -w -X BT_BLOCK 2>/dev/null
  done
  echo "规则已清除"
}

show_status() {
  local T
  for T in iptables ip6tables; do
    command -v "$T" >/dev/null 2>&1 || continue
    echo "========== $T =========="
    if "$T" -w -L BT_BLOCK -n >/dev/null 2>&1; then
      "$T" -w -C OUTPUT -j BT_BLOCK 2>/dev/null && echo "OUTPUT 链挂载：正常" || echo "OUTPUT 链挂载：缺失（执行 bt-block apply 修复）"
      echo "拦截计数（pkts 列为被丢弃的包数）："
      "$T" -w -L BT_BLOCK -v -n -x | tail -n +3
    else
      echo "未安装规则"
    fi
  done
  if command -v systemctl >/dev/null 2>&1 && [ -f /etc/systemd/system/bt-block.service ]; then
    echo "========== 开机自启 =========="
    systemctl is-enabled bt-block 2>/dev/null
  fi
}

# ---------------- 安装 / 卸载 ----------------

need_root() {
  [ "$(id -u)" -eq 0 ] || { red "请用 root 运行（sudo -i 后再执行）"; exit 1; }
}

ensure_deps() {
  if ! command -v iptables >/dev/null 2>&1; then
    yellow "未找到 iptables，正在安装 ..."
    if   command -v apt-get >/dev/null 2>&1; then apt-get update -qq >/dev/null 2>&1; apt-get install -y -qq iptables >/dev/null
    elif command -v dnf >/dev/null 2>&1;     then dnf install -y -q iptables
    elif command -v yum >/dev/null 2>&1;     then yum install -y -q iptables
    elif command -v apk >/dev/null 2>&1;     then apk add -q iptables ip6tables
    fi
  fi
  command -v iptables >/dev/null 2>&1 || { red "iptables 安装失败，请手动安装后重试"; exit 1; }
  modprobe xt_string 2>/dev/null || true
}

drop_count() {
  iptables -w -L BT_BLOCK -v -n -x 2>/dev/null | awk 'NR>2 && $3=="DROP" {s+=$1} END {print s+0}'
}

self_test() {
  # 向保留测试地址 192.0.2.1 发一个 UDP tracker 特征包，应被拦截并计数
  local before after
  before=$(drop_count)
  ( printf '\x00\x00\x04\x17\x27\x10\x19\x80\x00\x00\x00\x00' > /dev/udp/192.0.2.1/6969 ) 2>/dev/null
  after=$(drop_count)
  if [ "$after" -gt "$before" ]; then
    green "自检通过：测试特征包已被拦截"
  else
    yellow "自检未能确认（可能是系统 bash 不支持 /dev/udp），可稍后用 bt-block status 查看计数"
  fi
}

do_install() {
  need_root
  ensure_deps

  # 生成独立的管理命令
  {
    echo '#!/usr/bin/env bash'
    echo '# 由 bt-block.sh 生成'
    declare -f apply_rules remove_rules show_status
    echo 'case "${1:-}" in'
    echo '  apply)  apply_rules ;;'
    echo '  remove) remove_rules ;;'
    echo '  status) show_status ;;'
    echo '  *) echo "用法: bt-block {apply|remove|status}"; exit 1 ;;'
    echo 'esac'
  } > "$BIN"
  chmod 755 "$BIN"

  "$BIN" apply || { red "规则应用失败，请检查上方提示"; exit 1; }

  # 开机自启
  if command -v systemctl >/dev/null 2>&1; then
    cat > "$UNIT" <<EOF
[Unit]
Description=Block BitTorrent/DHT/Tracker outbound traffic
After=network-pre.target netfilter-persistent.service firewalld.service ufw.service docker.service
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$BIN apply
ExecStop=$BIN remove

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable bt-block >/dev/null 2>&1
    systemctl start bt-block >/dev/null 2>&1
    green "已设置开机自启（systemd: bt-block.service）"
  else
    yellow "系统没有 systemd，请把 \"$BIN apply\" 手动加入开机启动"
  fi

  self_test
  echo
  green "安装完成。常用命令："
  echo "  bt-block status   查看拦截计数"
  echo "  bt-block apply    重新应用规则（防火墙重载后规则丢失时使用）"
  echo "  bt-block remove   临时移除规则"
}

do_uninstall() {
  need_root
  if command -v systemctl >/dev/null 2>&1 && [ -f "$UNIT" ]; then
    systemctl disable --now bt-block >/dev/null 2>&1
    rm -f "$UNIT"
    systemctl daemon-reload
  fi
  remove_rules
  rm -f "$BIN"
  green "已卸载"
}

case "${1:-install}" in
  install)   do_install ;;
  uninstall) do_uninstall ;;
  status)    show_status ;;
  *) echo "用法: bash bt-block.sh [install|uninstall|status]"; exit 1 ;;
esac