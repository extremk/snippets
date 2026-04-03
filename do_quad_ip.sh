#!/bin/bash
# ====================================================
# DigitalOcean 四出口一键配置脚本 (适配 Ubuntu 24.04)
# 兼容 sing-box 1.12.0+ 新 DNS 格式 & 1.11.0+ 新路由动作
#
# 出口架构:
#   实例1: 主IPv4出口      (主端口)     - sb.json (原始，不修改)
#   实例2: 保留IPv4出口    (主端口+1)   - sb-reserved-v4.json
#   实例3: 主IPv6出口      (主端口+2)   - sb-ipv6.json
#   实例4: 保留IPv6出口    (主端口+3)   - sb-reserved-v6.json
#
# IPv6实例特性:
#   - 客户端入口: 严格 IPv4 (listen 0.0.0.0)
#   - 出口: 严格纯IPv6，绝不回退IPv4
#   - DNS: 强制 ipv6_only，新格式 DNS 服务器
#   - 路由: ip_version:4 + 0.0.0.0/0 双重拦截
#   - 出站: inet6_bind_address 强制绑定
# ====================================================

set -euo pipefail

# ── 1. 权限检查 ──────────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
    echo "❌ 请使用 root 权限运行此脚本"
    exit 1
fi

echo "============================================="
echo "🚀 DigitalOcean 四出口配置 (双IPv4 + 双IPv6)"
echo "============================================="

# ── 2. 依赖检查 ──────────────────────────────────────────────
for cmd in curl jq python3; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "📦 安装缺失依赖: $cmd ..."
        apt-get update -qq && apt-get install -y -qq "$cmd" 2>/dev/null || {
            echo "❌ 无法安装 $cmd，请手动安装"
            exit 1
        }
    fi
done

# 确保 python3 cryptography 库可用
python3 -c "from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey" 2>/dev/null || {
    echo "📦 安装 Python cryptography 库..."
    pip3 install cryptography -q 2>/dev/null || apt-get install -y -qq python3-cryptography 2>/dev/null || true
}

# ── 3. 检测 sing-box 版本 ───────────────────────────────────
SINGBOX_BIN=$(which sing-box 2>/dev/null || echo "/usr/local/bin/sing-box")
if [ -f "$SINGBOX_BIN" ]; then
    SB_VERSION=$($SINGBOX_BIN version 2>/dev/null | head -1 | grep -oP '\d+\.\d+\.\d+' || echo "0.0.0")
    SB_MAJOR=$(echo "$SB_VERSION" | cut -d. -f1)
    SB_MINOR=$(echo "$SB_VERSION" | cut -d. -f2)
    echo "📌 sing-box 版本: $SB_VERSION"
else
    SB_VERSION="0.0.0"
    SB_MAJOR=0
    SB_MINOR=0
    echo "⚠️  sing-box 未找到，将使用最新格式生成配置"
fi

# ── 4. 从 DigitalOcean 元数据 API 获取所有 IP 信息 ─────────
echo ""
echo "🔍 正在查询 DigitalOcean 元数据接口..."

METADATA_JSON=$(curl -sf http://169.254.169.254/metadata/v1.json 2>/dev/null) || {
    echo "❌ 无法访问 DO 元数据 API，请确认本机为 DigitalOcean Droplet"
    exit 1
}

echo "$METADATA_JSON" > /tmp/do_metadata_debug.json
echo "   💾 原始元数据已保存到 /tmp/do_metadata_debug.json"

# 使用分项 REST 端点逐一获取
MAIN_PUBLIC_IPV4=$(curl -sf http://169.254.169.254/metadata/v1/interfaces/public/0/ipv4/address 2>/dev/null || echo "")
MAIN_ANCHOR_IPV4=$(curl -sf http://169.254.169.254/metadata/v1/interfaces/public/0/anchor_ipv4/address 2>/dev/null || echo "")
ANCHOR_GATEWAY=$(curl -sf http://169.254.169.254/metadata/v1/interfaces/public/0/anchor_ipv4/gateway 2>/dev/null || echo "")
RESERVED_IPV4=$(curl -sf http://169.254.169.254/metadata/v1/reserved_ip/ipv4/ip_address 2>/dev/null || echo "")

# 主 IPv6 — REST 端点 + JSON 回退 + 系统接口回退
MAIN_IPV6=$(curl -sf http://169.254.169.254/metadata/v1/interfaces/public/0/ipv6/address 2>/dev/null || echo "")
MAIN_IPV6_GATEWAY=$(curl -sf http://169.254.169.254/metadata/v1/interfaces/public/0/ipv6/gateway 2>/dev/null || echo "")

if [ -z "$MAIN_IPV6" ]; then
    MAIN_IPV6=$(echo "$METADATA_JSON" | jq -r '
        (.interfaces.public // [])
        | if type == "array" then .[0] else . end
        | .ipv6
        | if type == "object" then .address
          elif type == "array" then .[0].address
          else empty end // empty
    ' 2>/dev/null || echo "")
fi

if [ -z "$MAIN_IPV6_GATEWAY" ]; then
    MAIN_IPV6_GATEWAY=$(echo "$METADATA_JSON" | jq -r '
        (.interfaces.public // [])
        | if type == "array" then .[0] else . end
        | .ipv6
        | if type == "object" then .gateway
          elif type == "array" then .[0].gateway
          else empty end // empty
    ' 2>/dev/null || echo "")
fi

if [ -z "$MAIN_IPV6" ]; then
    MAIN_IPV6=$(ip -6 addr show dev eth0 scope global | grep -v "deprecated\|temporary\|tentative" | grep "inet6" | head -1 | awk '{print $2}' | cut -d'/' -f1 || echo "")
fi

if [ -z "$MAIN_IPV6_GATEWAY" ]; then
    MAIN_IPV6_GATEWAY=$(ip -6 route show default dev eth0 | head -1 | awk '{print $3}' || echo "")
fi

# 保留 IPv6
RESERVED_IPV6=$(curl -sf http://169.254.169.254/metadata/v1/reserved_ip/ipv6/ip_address 2>/dev/null || echo "")
RESERVED_IPV6_ACTIVE=$(curl -sf http://169.254.169.254/metadata/v1/reserved_ip/ipv6/active 2>/dev/null || echo "")

if [ -z "$RESERVED_IPV6" ]; then
    RESERVED_IPV6=$(echo "$METADATA_JSON" | jq -r '.reserved_ip.ipv6.ip_address // empty' 2>/dev/null || echo "")
fi
if [ -z "$RESERVED_IPV6_ACTIVE" ]; then
    RESERVED_IPV6_ACTIVE=$(echo "$METADATA_JSON" | jq -r '.reserved_ip.ipv6.active // empty' 2>/dev/null || echo "")
fi

if [ -z "$MAIN_ANCHOR_IPV4" ]; then
    MAIN_ANCHOR_IPV4=$(echo "$METADATA_JSON" | jq -r '
        (.interfaces.public // [])
        | if type == "array" then .[0] else . end
        | .anchor_ipv4.address // empty
    ' 2>/dev/null || echo "")
fi

HOSTNAME_LABEL=$(curl -sf http://169.254.169.254/metadata/v1/hostname 2>/dev/null | cut -d'.' -f1 | tr '[:lower:]' '[:upper:]' || echo "NODE")

echo ""
echo "┌──────────────────────────────────────────────────────────┐"
echo "│                 IP 地址信息汇总                           │"
echo "├──────────────────────────────────────────────────────────┤"
printf "│ 主公网IPv4      : %-38s│\n" "${MAIN_PUBLIC_IPV4:-❌ 未获取}"
printf "│ Anchor IPv4     : %-38s│\n" "${MAIN_ANCHOR_IPV4:-⚠️  未检测}"
printf "│ Anchor Gateway  : %-38s│\n" "${ANCHOR_GATEWAY:-⚠️  未检测}"
printf "│ 保留 IPv4       : %-38s│\n" "${RESERVED_IPV4:-⚠️  未绑定}"
printf "│ 主 IPv6         : %-38s│\n" "${MAIN_IPV6:-❌ 未获取}"
printf "│ IPv6 网关       : %-38s│\n" "${MAIN_IPV6_GATEWAY:-⚠️  未获取}"
printf "│ 保留 IPv6       : %-38s│\n" "${RESERVED_IPV6:-⚠️  未绑定}"
printf "│ 保留IPv6已激活  : %-38s│\n" "${RESERVED_IPV6_ACTIVE:-⚠️  未知}"
printf "│ 节点标签        : %-38s│\n" "$HOSTNAME_LABEL"
printf "│ sing-box 版本   : %-38s│\n" "$SB_VERSION"
echo "└──────────────────────────────────────────────────────────┘"

# ── 5. 验证必要的 IP 地址 ────────────────────────────────────
ERRORS=()
WARNINGS=()

if [ -z "$MAIN_PUBLIC_IPV4" ]; then
    ERRORS+=("主公网IPv4地址不可用")
fi

if [ -z "$MAIN_ANCHOR_IPV4" ]; then
    WARNINGS+=("未检测到 Anchor IPv4，实例2(保留IPv4出口)将跳过")
    HAS_RESERVED_V4=false
else
    HAS_RESERVED_V4=true
fi

if [ -z "$RESERVED_IPV4" ]; then
    WARNINGS+=("未检测到保留IPv4，实例2订阅链接将使用主IPv4")
    RESERVED_IPV4_FOR_LINK="$MAIN_PUBLIC_IPV4"
else
    RESERVED_IPV4_FOR_LINK="$RESERVED_IPV4"
fi

if [ -z "$MAIN_IPV6" ]; then
    ERRORS+=("主IPv6地址不可用 — 请在DO控制面板启用IPv6")
fi

if [ -z "$RESERVED_IPV6" ]; then
    WARNINGS+=("保留IPv6地址不可用，实例4将跳过")
    HAS_RESERVED_V6=false
elif [ "$RESERVED_IPV6_ACTIVE" != "true" ]; then
    WARNINGS+=("保留IPv6未激活(active=$RESERVED_IPV6_ACTIVE)，实例4将跳过")
    HAS_RESERVED_V6=false
else
    HAS_RESERVED_V6=true
fi

if [ ${#WARNINGS[@]} -gt 0 ]; then
    echo ""
    echo "⚠️  警告:"
    for w in "${WARNINGS[@]}"; do
        echo "   • $w"
    done
fi

if [ ${#ERRORS[@]} -gt 0 ]; then
    echo ""
    echo "❌ 致命错误:"
    for err in "${ERRORS[@]}"; do
        echo "   • $err"
    done
    echo ""
    echo "💡 调试: cat /tmp/do_metadata_debug.json | jq ."
    echo "         ip -6 addr show dev eth0 scope global"
    exit 1
fi

# ── 6. 检查原始配置文件 ──────────────────────────────────────
SOURCE_FILE="/etc/s-box/sb.json"
if [ ! -f "$SOURCE_FILE" ]; then
    echo "❌ 找不到原配置文件 $SOURCE_FILE"
    exit 1
fi
echo ""
echo "✅ 原始配置文件: $SOURCE_FILE"

# ── 7. 配置内核级 IPv6 路由 ──────────────────────────────────
echo ""
echo "⚙️  配置内核级 IPv6 路由..."

sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.eth0.disable_ipv6=0 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.lo.disable_ipv6=0 >/dev/null 2>&1 || true
echo "   ├─ ✅ 系统 IPv6 已启用"

if [ "$HAS_RESERVED_V6" = true ]; then
    ip -6 addr replace "${RESERVED_IPV6}/128" dev lo scope global 2>/dev/null || {
        ip -6 addr add "${RESERVED_IPV6}/128" dev lo scope global 2>/dev/null || true
    }
    if ip -6 addr show dev lo | grep -q "$RESERVED_IPV6"; then
        echo "   ├─ ✅ 保留 IPv6 已绑定到 lo"
    else
        echo "   ├─ ❌ 保留 IPv6 绑定失败"
        HAS_RESERVED_V6=false
    fi
fi

if ! ip -6 addr show dev eth0 scope global | grep -q "$MAIN_IPV6"; then
    echo "   ├─ 添加主 IPv6 到 eth0..."
    MAIN_IPV6_PREFIX=$(echo "$METADATA_JSON" | jq -r '
        (.interfaces.public // []) | if type == "array" then .[0] else . end
        | .ipv6 | if type == "object" then .prefix elif type == "array" then .[0].prefix else empty end // empty
    ' 2>/dev/null || echo "64")
    [ -z "$MAIN_IPV6_PREFIX" ] && MAIN_IPV6_PREFIX="64"
    ip -6 addr add "${MAIN_IPV6}/${MAIN_IPV6_PREFIX}" dev eth0 scope global 2>/dev/null || true
fi

if ! ip -6 route show default | grep -q "default"; then
    if [ -n "$MAIN_IPV6_GATEWAY" ]; then
        ip -6 route add default via "$MAIN_IPV6_GATEWAY" dev eth0 2>/dev/null || true
    fi
fi
echo "   ├─ ✅ IPv6 路由已确认"

if ping6 -c 1 -W 3 2606:4700:4700::1111 >/dev/null 2>&1; then
    echo "   ├─ ✅ IPv6 连通正常"
else
    echo "   ├─ ⚠️  IPv6 ping 失败（可能仅ICMP被阻）"
fi

# 持久化脚本
PERSIST_SCRIPT="/etc/s-box/setup-ipv6-routes.sh"
mkdir -p /etc/s-box
cat > "$PERSIST_SCRIPT" << EOFPERSIST
#!/bin/bash
sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.lo.disable_ipv6=0 >/dev/null 2>&1 || true
RESERVED_IPV6="${RESERVED_IPV6}"
HAS_RESERVED_V6="${HAS_RESERVED_V6}"
if [ "\$HAS_RESERVED_V6" = "true" ] && [ -n "\$RESERVED_IPV6" ]; then
    ip -6 addr replace "\${RESERVED_IPV6}/128" dev lo scope global 2>/dev/null || true
fi
echo "[\$(date)] IPv6 routes restored" >> /var/log/do-ipv6-routes.log
EOFPERSIST
chmod +x "$PERSIST_SCRIPT"

cat > /etc/systemd/system/do-ipv6-routes.service << EOFSVC
[Unit]
Description=DigitalOcean IPv6 Route Persistence
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=${PERSIST_SCRIPT}
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOFSVC
systemctl daemon-reload
systemctl enable do-ipv6-routes.service >/dev/null 2>&1
echo "   └─ ✅ 持久化服务已注册"

# ── 8. Python 生成配置文件和订阅链接 ─────────────────────────
echo ""
echo "⚙️  正在生成配置文件和订阅链接..."

python3 << PYEOF
import json
import sys
import copy
import base64
import os
from urllib.parse import quote

# ── 参数 ──────────────────────────────────────────────────
source_file      = "$SOURCE_FILE"
anchor_ipv4      = "$MAIN_ANCHOR_IPV4"
main_public_ipv4 = "$MAIN_PUBLIC_IPV4"
reserved_ipv4    = "$RESERVED_IPV4_FOR_LINK"
main_ipv6        = "$MAIN_IPV6"
reserved_ipv6    = "$RESERVED_IPV6"
hostname         = "$HOSTNAME_LABEL"
ipv6_gateway     = "$MAIN_IPV6_GATEWAY"
has_reserved_v4  = "$HAS_RESERVED_V4" == "true"
has_reserved_v6  = "$HAS_RESERVED_V6" == "true"
sb_version       = "$SB_VERSION"

CONFIG_DIR = "/etc/s-box"

# 解析版本号
try:
    sv = [int(x) for x in sb_version.split('.')]
    sb_major, sb_minor = sv[0], sv[1]
except:
    sb_major, sb_minor = 99, 99  # 假设最新

print(f"   sing-box 版本: {sb_version} (major={sb_major}, minor={sb_minor})")

# ── 加载原始配置 ──────────────────────────────────────────
try:
    with open(source_file, 'r', encoding='utf-8') as f:
        original_config = json.load(f)
except Exception as e:
    print(f'❌ 解析原始配置失败: {e}')
    sys.exit(1)

print(f"   ✅ 原始配置已加载，{len(original_config.get('inbounds', []))} 个入站")

# ══════════════════════════════════════════════════════════
# 工具函数
# ══════════════════════════════════════════════════════════

def derive_x25519_pubkey(private_key_b64url):
    try:
        from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
        from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
        pad = private_key_b64url + '=' * (-len(private_key_b64url) % 4)
        raw = base64.urlsafe_b64decode(pad)
        priv = X25519PrivateKey.from_private_bytes(raw)
        pub_raw = priv.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
        return base64.urlsafe_b64encode(pub_raw).rstrip(b'=').decode()
    except:
        return ""

def get_common_sni(config):
    for inbound in config.get('inbounds', []):
        if inbound.get('type') == 'vmess':
            sni = inbound.get('tls', {}).get('server_name', '')
            if sni:
                return sni
    return "www.bing.com"

def shift_ports(config, offset):
    for inbound in config.get('inbounds', []):
        if 'listen_port' in inbound and isinstance(inbound['listen_port'], int):
            old = inbound['listen_port']
            inbound['listen_port'] = old + offset
            print(f"      端口: {old} -> {old + offset}")

def force_ipv4_listen(config):
    """强制所有入站监听 IPv4 only (0.0.0.0)"""
    for inbound in config.get('inbounds', []):
        inbound['listen'] = '0.0.0.0'

def build_strict_ipv6_dns():
    """
    构建严格纯 IPv6 DNS — 兼容 sing-box 1.12.0+ 新格式

    新格式要求:
    - type: "tls" 替代 address: "tls://..."
    - server: 服务器地址
    - server_port: 端口
    - address_resolver / address_strategy 在新格式中被替换

    关键: strategy 全局和每个服务器都是 ipv6_only
    使用 IPv6 地址直连 DNS 服务器，无需域名解析
    """
    return {
        "servers": [
            {
                "tag": "ipv6-dns-cf",
                "type": "tls",
                "server": "2606:4700:4700::1111",
                "server_port": 853,
                "strategy": "ipv6_only"
            },
            {
                "tag": "ipv6-dns-google",
                "type": "tls",
                "server": "2001:4860:4860::8888",
                "server_port": 853,
                "strategy": "ipv6_only"
            },
            {
                "tag": "block-dns",
                "type": "rcode",
                "rcode": "refused"
            }
        ],
        "final": "ipv6-dns-cf",
        "strategy": "ipv6_only",
        "disable_cache": False,
        "independent_cache": True
    }

def build_strict_ipv6_route():
    """
    构建严格 IPv6 路由规则

    sing-box 1.11.0+ 不再使用 block outbound，改用 route rule action

    五层防护:
    1. sniff — 提取 SNI/域名
    2. hijack-dns — 劫持 DNS 到本地 ipv6_only 解析器
    3. reject ip_version:4 — 拦截所有 IPv4 目标
    4. reject 0.0.0.0/0 — 双重保险
    5. route -> direct (已绑定 IPv6)

    final: "reject" action — 零信任兜底
    auto_detect_interface: false — 禁止自动路由探测
    """
    return {
        "rules": [
            {
                "action": "sniff",
                "timeout": "1s"
            },
            {
                "protocol": "dns",
                "action": "hijack-dns"
            },
            {
                "ip_version": 4,
                "action": "reject",
                "method": "default"
            },
            {
                "ip_cidr": ["0.0.0.0/0"],
                "action": "reject",
                "method": "default"
            },
            {
                "action": "route",
                "outbound": "direct"
            }
        ],
        "final": "reject",
        "auto_detect_interface": False
    }

def build_ipv6_outbounds(bind_ipv6_addr):
    """
    构建严格 IPv6 出站

    sing-box 1.11.0+ 不再需要 block outbound
    final route 直接使用 action: reject

    参数说明:
    - inet6_bind_address: 强制 bind() 到指定 IPv6
    - bind_interface: eth0 — SO_BINDTODEVICE 锁定物理接口
    - bind_address_no_port: true — 防高并发端口耗尽
    - tcp_multi_path: false — 禁 MPTCP 防 IPv4 子流
    - tcp_fast_open: false — 避免严格 IPv6 路径上的 TFO 异常
    - domain_resolver: 指定 DNS 解析器（新格式需要）
    """
    return [
        {
            "type": "direct",
            "tag": "direct",
            "bind_interface": "eth0",
            "inet6_bind_address": bind_ipv6_addr,
            "bind_address_no_port": True,
            "tcp_multi_path": False,
            "tcp_fast_open": False,
            "udp_fragment": True,
            "domain_resolver": "ipv6-dns-cf"
        }
    ]

def apply_ipv6_strict_config(config, bind_ipv6_addr):
    """
    完整转换配置为严格 IPv6-only 出口模式

    1. 入站: listen 0.0.0.0 (IPv4 only 入口)
    2. DNS: 严格 ipv6_only 新格式
    3. 路由: IPv4 全拒绝 + IPv6 放行 + reject 兜底
    4. 出站: IPv6 绑定 (无 block outbound)
    5. 移除 endpoints (warp 等可能泄漏 IPv4)
    """
    force_ipv4_listen(config)
    config['dns'] = build_strict_ipv6_dns()
    config['route'] = build_strict_ipv6_route()
    config['outbounds'] = build_ipv6_outbounds(bind_ipv6_addr)
    if 'endpoints' in config:
        del config['endpoints']
    return config


# ══════════════════════════════════════════════════════════
# 生成各实例配置
# ══════════════════════════════════════════════════════════

generated_instances = []

# ── 实例2: 保留 IPv4 (端口+1) ────────────────────────────
if has_reserved_v4 and anchor_ipv4:
    print(f"\n📋 实例2: 保留 IPv4 出口 (端口+1, Anchor: {anchor_ipv4})")
    config_rv4 = copy.deepcopy(original_config)
    shift_ports(config_rv4, 1)

    bound = False
    for outbound in config_rv4.get('outbounds', []):
        if outbound.get('tag') == 'direct' and outbound.get('type') == 'direct':
            outbound['inet4_bind_address'] = anchor_ipv4
            outbound['udp_fragment'] = True
            outbound['bind_address_no_port'] = True
            print(f"      出站绑定: {anchor_ipv4}")
            bound = True
            break

    if not bound:
        config_rv4.setdefault('outbounds', []).insert(0, {
            "type": "direct",
            "tag": "direct",
            "inet4_bind_address": anchor_ipv4,
            "udp_fragment": True,
            "bind_address_no_port": True
        })
        print(f"      创建新 direct 出站绑定: {anchor_ipv4}")

    rv4_file = f"{CONFIG_DIR}/sb-reserved-v4.json"
    with open(rv4_file, 'w', encoding='utf-8') as f:
        json.dump(config_rv4, f, indent=4, ensure_ascii=False)
    print(f"      ✅ 已保存: {rv4_file}")
    generated_instances.append(("reserved-v4", rv4_file, config_rv4, reserved_ipv4, "保留IPv4"))
else:
    print(f"\n⏭️  实例2: 跳过（无 Anchor IPv4）")


# ── 实例3: 主 IPv6 (端口+2) ──────────────────────────────
print(f"\n📋 实例3: 主 IPv6 出口 (端口+2, 绑定: {main_ipv6})")
config_v6 = copy.deepcopy(original_config)
shift_ports(config_v6, 2)
apply_ipv6_strict_config(config_v6, main_ipv6)

v6_file = f"{CONFIG_DIR}/sb-ipv6.json"
with open(v6_file, 'w', encoding='utf-8') as f:
    json.dump(config_v6, f, indent=4, ensure_ascii=False)
print(f"      ✅ 已保存: {v6_file}")
generated_instances.append(("ipv6", v6_file, config_v6, main_public_ipv4, "主IPv6"))


# ── 实例4: 保留 IPv6 (端口+3) ────────────────────────────
if has_reserved_v6 and reserved_ipv6:
    print(f"\n📋 实例4: 保留 IPv6 出口 (端口+3, 绑定: {reserved_ipv6})")
    config_rv6 = copy.deepcopy(original_config)
    shift_ports(config_rv6, 3)
    apply_ipv6_strict_config(config_rv6, reserved_ipv6)

    rv6_file = f"{CONFIG_DIR}/sb-reserved-v6.json"
    with open(rv6_file, 'w', encoding='utf-8') as f:
        json.dump(config_rv6, f, indent=4, ensure_ascii=False)
    print(f"      ✅ 已保存: {rv6_file}")
    generated_instances.append(("reserved-v6", rv6_file, config_rv6, main_public_ipv4, "保留IPv6"))
else:
    print(f"\n⏭️  实例4: 跳过（无保留 IPv6）")


# ══════════════════════════════════════════════════════════
# 生成订阅链接
# ══════════════════════════════════════════════════════════

common_sni = get_common_sni(original_config)

def generate_links(config, connect_ip, label_suffix):
    links = []
    for inbound in config.get('inbounds', []):
        itype = inbound.get('type')
        port  = inbound.get('listen_port')
        tag   = inbound.get('tag', '').replace('-sb', '')
        label = f"{tag}-{hostname}-{label_suffix}"
        tls   = inbound.get('tls', {})
        sni   = tls.get('server_name', common_sni) or common_sni

        if itype == 'vless':
            uuid = inbound['users'][0]['uuid']
            flow = inbound['users'][0].get('flow', 'xtls-rprx-vision')
            reality = tls.get('reality', {})
            priv_key = reality.get('private_key', '')
            short_id = reality.get('short_id', [''])[0]
            pbk = derive_x25519_pubkey(priv_key) if priv_key else ''
            link = (
                f"vless://{uuid}@{connect_ip}:{port}"
                f"?encryption=none&flow={flow}&security=reality"
                f"&sni={sni}&fp=chrome&pbk={pbk}&sid={short_id}"
                f"&type=tcp&headerType=none#{label}"
            )
            links.append(('VLESS Reality', link))

        elif itype == 'vmess':
            uuid = inbound['users'][0]['uuid']
            transport = inbound.get('transport', {})
            path = transport.get('path', '')
            tls_on = tls.get('enabled', False)
            vmess_label = f"vm-ws-{hostname}-{label_suffix}"
            vmess_obj = {
                "v": "2", "ps": vmess_label, "add": connect_ip,
                "port": str(port), "id": uuid, "aid": "0", "scy": "auto",
                "net": "ws", "type": "none", "host": sni, "path": path,
                "tls": "tls" if tls_on else "",
                "sni": sni if tls_on else "",
                "alpn": "", "fp": "", "insecure": "0"
            }
            encoded = base64.b64encode(
                json.dumps(vmess_obj, separators=(',', ': '), ensure_ascii=False).encode()
            ).decode()
            links.append(('VMess WS', f"vmess://{encoded}"))

        elif itype == 'hysteria2':
            password = inbound['users'][0]['password']
            link = (
                f"hysteria2://{password}@{connect_ip}:{port}"
                f"?sni={sni}&alpn=h3&insecure=1&allowInsecure=1#{label}"
            )
            links.append(('Hysteria2', link))

        elif itype == 'tuic':
            uuid = inbound['users'][0]['uuid']
            password = inbound['users'][0]['password']
            auth = quote(f"{uuid}:{password}", safe='')
            link = (
                f"tuic://{auth}@{connect_ip}:{port}"
                f"?sni={sni}&alpn=h3&insecure=1&allowInsecure=1&congestion_control=bbr#{label}"
            )
            links.append(('TUIC v5', link))

        elif itype == 'anytls':
            password = inbound['users'][0]['password']
            link = (
                f"anytls://{password}@{connect_ip}:{port}"
                f"?security=tls&sni={sni}&insecure=1&allowInsecure=1&type=tcp#{label}"
            )
            links.append(('AnyTLS', link))

    return links


# ── 收集并输出链接 ───────────────────────────────────────
all_sections = []

links1 = generate_links(original_config, main_public_ipv4, "主IPv4")
all_sections.append(("实例1-主IPv4", f"出口: {main_public_ipv4}", links1))

for inst_id, inst_file, inst_config, inst_connect_ip, inst_label in generated_instances:
    links = generate_links(inst_config, inst_connect_ip, inst_label)
    if "ipv6" in inst_id.lower():
        if "reserved" in inst_id:
            info = f"入口: {main_public_ipv4} → 出口: {reserved_ipv6}"
        else:
            info = f"入口: {main_public_ipv4} → 出口: {main_ipv6}"
    else:
        info = f"出口: {inst_connect_ip}"
    all_sections.append((f"实例-{inst_label}", info, links))

for section_name, section_info, section_links in all_sections:
    print(f"\n{'='*60}")
    print(f"  📡 {section_name} | {section_info}")
    print(f"{'='*60}")
    for name, link in section_links:
        display = link[:90] + "..." if len(link) > 100 else link
        print(f"  📌 {name}: {display}")

# ── 保存链接文件 ─────────────────────────────────────────
links_file = f"{CONFIG_DIR}/all-links.txt"
with open(links_file, 'w', encoding='utf-8') as f:
    f.write(f"# DigitalOcean 四出口节点订阅链接\n")
    f.write(f"# 节点: {hostname} | 主IPv4: {main_public_ipv4}\n")
    f.write(f"# 保留IPv4: {reserved_ipv4} | 主IPv6: {main_ipv6}\n")
    f.write(f"# 保留IPv6: {reserved_ipv6}\n\n")
    for section_name, section_info, section_links in all_sections:
        f.write(f"{'#'*60}\n# {section_name} | {section_info}\n{'#'*60}\n\n")
        for name, link in section_links:
            f.write(f"# {name}\n{link}\n\n")
        f.write("\n")

print(f"\n💾 订阅链接: {links_file}")

for idx, (sn, si, sl) in enumerate(all_sections, 1):
    with open(f"{CONFIG_DIR}/links-instance{idx}.txt", 'w', encoding='utf-8') as f:
        f.write(f"# {sn} | {si}\n\n")
        for name, link in sl:
            f.write(f"# {name}\n{link}\n\n")

print("💾 各实例链接已分别保存")

# 输出实例信息
with open(f"{CONFIG_DIR}/.generated_instances", 'w') as f:
    for inst_id, inst_file, _, _, inst_label in generated_instances:
        f.write(f"{inst_id}|{inst_file}|{inst_label}\n")

PYEOF

if [ $? -ne 0 ]; then
    echo "❌ 配置生成失败"
    exit 1
fi

# ── 9. 配置 systemd 服务 ─────────────────────────────────────
echo ""
echo "⚙️  配置 systemd 服务..."

SERVICE_SOURCE="/etc/systemd/system/sing-box.service"
if [ ! -f "$SERVICE_SOURCE" ]; then
    echo "❌ 找不到 $SERVICE_SOURCE"
    exit 1
fi

INSTANCE_INFO="/etc/s-box/.generated_instances"
if [ -f "$INSTANCE_INFO" ]; then
    while IFS='|' read -r INST_ID INST_FILE INST_LABEL; do
        SVC_NAME="sing-box-${INST_ID}"
        SVC_FILE="/etc/systemd/system/${SVC_NAME}.service"
        CFG_BASENAME=$(basename "$INST_FILE")
        sed "s|sb\.json|${CFG_BASENAME}|g" "$SERVICE_SOURCE" > "$SVC_FILE"
        sed -i "s/Description=.*/Description=sing-box ${INST_LABEL} Instance/" "$SVC_FILE"
        echo "   ├─ ✅ ${SVC_NAME}.service (${INST_LABEL})"
    done < "$INSTANCE_INFO"
fi

# ── 10. 验证配置文件 ─────────────────────────────────────────
echo ""
echo "🔍 验证配置文件..."

ALL_VALID=true
if [ -f "$INSTANCE_INFO" ]; then
    while IFS='|' read -r INST_ID INST_FILE INST_LABEL; do
        if $SINGBOX_BIN check -c "$INST_FILE" 2>/dev/null; then
            echo "   ├─ ✅ ${INST_LABEL} ($(basename $INST_FILE))"
        else
            echo "   ├─ ❌ ${INST_LABEL} ($(basename $INST_FILE))"
            $SINGBOX_BIN check -c "$INST_FILE" 2>&1 | head -5 | sed 's/^/   │  /'
            ALL_VALID=false
        fi
    done < "$INSTANCE_INFO"
fi

if [ "$ALL_VALID" = false ]; then
    echo ""
    echo "⚠️  部分配置验证失败，当前 sing-box: $SB_VERSION"
fi

# ── 11. 启动服务 ─────────────────────────────────────────────
echo ""
echo "🚀 启动服务..."

systemctl daemon-reload

if [ -f "$INSTANCE_INFO" ]; then
    while IFS='|' read -r INST_ID INST_FILE INST_LABEL; do
        SVC_NAME="sing-box-${INST_ID}"
        systemctl enable "$SVC_NAME" >/dev/null 2>&1
        systemctl restart "$SVC_NAME" 2>/dev/null
        sleep 1
        if systemctl is-active --quiet "$SVC_NAME"; then
            echo "   ├─ ✅ ${SVC_NAME} (${INST_LABEL}) - 运行中"
        else
            echo "   ├─ ❌ ${SVC_NAME} (${INST_LABEL}) - 启动失败"
            journalctl -u "$SVC_NAME" --no-pager -n 5 2>/dev/null | sed 's/^/   │  /'
        fi
    done < "$INSTANCE_INFO"
fi

# ── 12. 验证出口 ─────────────────────────────────────────────
echo ""
echo "🔍 验证出口 IP..."
SYS_V4=$(curl -4 -sf --connect-timeout 5 --max-time 10 https://api.ipify.org 2>/dev/null || echo "无法获取")
SYS_V6=$(curl -6 -sf --connect-timeout 5 --max-time 10 https://api6.ipify.org 2>/dev/null || echo "无法获取")
printf "   IPv4 出口: %-40s (期望: %s)\n" "$SYS_V4" "$MAIN_PUBLIC_IPV4"
printf "   IPv6 出口: %-40s (期望: %s)\n" "$SYS_V6" "$MAIN_IPV6"

# ── 13. IPv6 状态 ────────────────────────────────────────────
echo ""
echo "📋 IPv6 状态:"
echo "   eth0:"
ip -6 addr show dev eth0 scope global 2>/dev/null | sed 's/^/      /' || echo "      (无)"
echo "   lo:"
ip -6 addr show dev lo scope global 2>/dev/null | sed 's/^/      /' || echo "      (无)"

# ── 14. 最终报告 ─────────────────────────────────────────────
echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║                  🎉 四出口配置完成！                          ║"
echo "╠═══════════════════════════════════════════════════════════════╣"
printf "║  实例1: 主IPv4     | %-40s║\n" "$MAIN_PUBLIC_IPV4 (原始)"
[ "$HAS_RESERVED_V4" = true ] && \
printf "║  实例2: 保留IPv4   | %-40s║\n" "$RESERVED_IPV4_FOR_LINK (端口+1)"
printf "║  实例3: 主IPv6     | %-40s║\n" "$MAIN_IPV6 (端口+2)"
[ "$HAS_RESERVED_V6" = true ] && \
printf "║  实例4: 保留IPv6   | %-40s║\n" "$RESERVED_IPV6 (端口+3)"
echo "╠═══════════════════════════════════════════════════════════════╣"
echo "║  📁 /etc/s-box/sb.json                    (实例1)            ║"
[ "$HAS_RESERVED_V4" = true ] && \
echo "║  📁 /etc/s-box/sb-reserved-v4.json        (实例2)            ║"
echo "║  📁 /etc/s-box/sb-ipv6.json               (实例3)            ║"
[ "$HAS_RESERVED_V6" = true ] && \
echo "║  📁 /etc/s-box/sb-reserved-v6.json        (实例4)            ║"
echo "║  🔗 /etc/s-box/all-links.txt              (所有链接)         ║"
echo "╠═══════════════════════════════════════════════════════════════╣"
echo "║  ⚠️  IPv6 严格模式:                                          ║"
echo "║     • DNS: 仅 AAAA 记录 (新格式 type:tls)                   ║"
echo "║     • 路由: ip_version:4 + 0.0.0.0/0 双重拒绝               ║"
echo "║     • 出站: inet6_bind_address 绑定 + domain_resolver        ║"
echo "║     • 兜底: final: reject (无 block outbound)                ║"
echo "║     • 纯IPv4网站将无法访问（预期行为）                       ║"
echo "╠═══════════════════════════════════════════════════════════════╣"
echo "║  🛠️  管理:                                                    ║"
echo "║  systemctl status sing-box                        (主IPv4)   ║"
[ "$HAS_RESERVED_V4" = true ] && \
echo "║  systemctl status sing-box-reserved-v4            (保留IPv4) ║"
echo "║  systemctl status sing-box-ipv6                   (主IPv6)   ║"
[ "$HAS_RESERVED_V6" = true ] && \
echo "║  systemctl status sing-box-reserved-v6            (保留IPv6) ║"
echo "║  cat /etc/s-box/all-links.txt                     (链接)     ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
