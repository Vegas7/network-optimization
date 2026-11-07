# bbr-optimization
一个精简的 Linux TCP/IP &amp; BBR 参数智能优化脚本

## 功能特点
- BBR + TCP 智能调参一键脚本
- 自动识别 VPS 的核心和内存数，智能配置网络参数
- 支持Debian 和 Ubuntu
- 支持自动备份管理功能
- 支持一键撤销修改和恢复备份

## 一键安装
```
bash <(curl -sL https://raw.githubusercontent.com/Vegas7/network-optimization/main/script.sh)
```

## 其他用法
```
# 只预览将要写入的配置，不做任何修改
bash <(curl -sL https://raw.githubusercontent.com/Vegas7/network-optimization/main/script.sh) --dry-run

# 恢复最近一次备份的配置
bash <(curl -sL https://raw.githubusercontent.com/Vegas7/network-optimization/main/script.sh) restore

# 删除配置并把参数恢复到首次安装前
bash <(curl -sL https://raw.githubusercontent.com/Vegas7/network-optimization/main/script.sh) uninstall
```

## 可选环境变量
- `RESERVED_PORTS="443,8443,20000-30000"`：从本地临时端口范围中保留这些端口，避免出站连接占用服务端口。之后重跑脚本会沿用上次的值，设为空串 `RESERVED_PORTS=""` 则取消保留。
- `FIX_SYSCTL_CONF=1`：`/etc/sysctl.conf` 中有会覆盖本脚本的同名参数时，自动注释掉（会先备份，`uninstall` 时自动还原）；`FIX_SYSCTL_CONF=0` 只提示不修改；不设置时交互询问。

```
RESERVED_PORTS="443,8443" bash <(curl -sL https://raw.githubusercontent.com/Vegas7/network-optimization/main/script.sh)
```
