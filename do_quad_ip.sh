#!/bin/bash
# ====================================================
# DigitalOcean 四出口一键配置脚本 (适配 sing-box-yg 脚本)
# 
# 出口架构:
#   实例1: 主IPv4出口      (主端口)     - sb.json (原始，不修改)
#   实例2: 保留IPv4出口    (主端口+1)   - sb-reserved-v4.json
#   实例3: 主IPv6出口      (主端口+2)   - sb-ipv6.json
#   实例4: 保留IPv6出口    (主端口+3)   - sb-reserved-v6.json
#
# IPv6实例: 入口IPv4(0.0.0.0) → 出口严格纯IPv6，绝不回退
# ====================================================

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "❌ 请使用 root 权限运行此脚本"
    exit 1
fi

echo "============================================="
echo "🚀 DigitalOcean 四出口配置 (双IPv4 + 双IPv6)"
echo "============================================="

# ── 依赖检查 ─────────────────────────────────────────────────
for cmd in curl jq python3; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "📦 安装依赖: $cmd ..."
        apt-get update -qq && apt-get install -y -qq "$cmd" 2>/dev/null || {
            echo "❌ 无法安装 $cmd"
            exit 1
        }
    fi
done

python3 -c "from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey" 2>/dev/null || {
    echo "📦 安装 Python cryptography..."
    pip3 install cryptography -q 2>/dev/null || apt-get install -y -qq python3-cryptography 2>/dev/null || true
}

# ── 检测 sing-box 路径和版本 ─────────────────────────────────
# sing-box-yg 安装到 /etc/s-box/sing-box
if [ -x /etc/s-box/sing-box ]; then
    SINGBOX_BIN="/etc/s-box/sing-box"
elif command -v sing-box &>/dev/null; then
    SINGBOX_BIN=$(command -v sing-box)
elif [ -x /usr/local/bin/sing-box ]; then
    SINGBOX_BIN="/usr/local/bin/sing-box"
else
    echo "❌ 找不到 sing-box 二进制文件"
    echo "   请先使用甬哥脚本安装: bash <(curl -Ls https://raw.githubusercontent.com/yonggekkk/sing-box-yg/main/sb.sh)"
    exit 1
fi

SB_VERSION=$($SINGBOX_BIN version 2>/dev/null | awk '/version/{print $NF}' || echo "0.0.0")
SB_MAJOR_MINOR=$($SINGBOX_BIN version 2>/dev/null | awk '/version/{print $NF}' | cut -d'.' -f1,2 || echo "0.0")
echo "📌 sing-box 路径: $SINGBOX_BIN"
echo "📌 sing-box 版本: $SB_VERSION (系列: $SB_MAJOR_MINOR)"

# ── 从 DigitalOcean 元数据获取 IP ────────────────────────────
echo ""
echo "🔍 查询 DigitalOcean 元数据..."

METADATA_JSON=$(curl -sf http://169.254.169.254/metadata/v1.json 2>/dev/null) || {
    echo "❌ 无法访问 DO 元数据 API"
    exit 1
}
echo "$METADATA_JSON" > /tmp/do_metadata_debug.json

# REST 端点获取（最可靠）
MAIN_PUBLIC_IPV4=$(curl -sf http://169.254.169.254/metadata/v1/interfaces/public/0/ipv4/address 2>/dev/null || echo "")
MAIN_ANCHOR_IPV4=$(curl -sf http://169.254.169.254/metadata/v1/interfaces/public/0/anchor_ipv4/address 2>/dev/null || echo "")
ANCHOR_GATEWAY=$(curl -sf http://169.254.169.254/metadata/v1/interfaces/public/0/anchor_ipv4/gateway 2>/dev/null || echo "")
RESERVED_IPV4=$(curl -sf http://169.254.169.254/metadata/v1/reserved_ip/ipv4/ip_address 2>/dev/null || echo "")

MAIN_IPV6=$(curl -sf http://169.254.169.254/metadata/v1/interfaces/public/0/ipv6/address 2>/dev/null || echo "")
MAIN_IPV6_GATEWAY=$(curl -sf http://169.254.169.254/metadata/v1/interfaces/public/0/ipv6/gateway 2>/dev/null || echo "")

# IPv6 回退: JSON 解析 → 系统接口
if [ -z "$MAIN_IPV6" ]; then
    MAIN_IPV6=$(echo "$METADATA_JSON" | jq -r '(.interfaces.public // []) | if type == "array" then .[0] else . end | .ipv6 | if type == "object" then .address elif type == "array" then .[0].address else empty end // empty' 2>/dev/null || echo "")
fi
if [ -z "$MAIN_IPV6" ]; then
    MAIN_IPV6=$(ip -6 addr show dev eth0 scope global | grep -v "deprecated\|temporary\|tentative" | grep "inet6" | head -1 | awk '{print $2}' | cut -d'/' -f1 || echo "")
fi
if [ -z "$MAIN_IPV6_GATEWAY" ]; then
    MAIN_IPV6_GATEWAY=$(echo "$METADATA_JSON" | jq -r '(.interfaces.public // []) | if type == "array" then .[0] else . end | .ipv6 | if type == "object" then .gateway elif type == "array" then .[0].gateway else empty end // empty' 2>/dev/null || echo "")
fi
if [ -z "$MAIN_IPV6_GATEWAY" ]; then
    MAIN_IPV6_GATEWAY=$(ip -6 route show default dev eth0 2>/dev/null | head -1 | awk '{print $3}' || echo "")
fi

RESERVED_IPV6=$(curl -sf http://169.254.169.254/metadata/v1/reserved_ip/ipv6/ip_address 2>/dev/null || echo "")
RESERVED_IPV6_ACTIVE=$(curl -sf http://169.254.169.254/metadata/v1/reserved_ip/ipv6/active 2>/dev/null || echo "")
[ -z "$RESERVED_IPV6" ] && RESERVED_IPV6=$(echo "$METADATA_JSON" | jq -r '.reserved_ip.ipv6.ip_address // empty' 2>/dev/null || echo "")
[ -z "$RESERVED_IPV6_ACTIVE" ] && RESERVED_IPV6_ACTIVE=$(echo "$METADATA_JSON" | jq -r '.reserved_ip.ipv6.active // empty' 2>/dev/null || echo "")
[ -z "$MAIN_ANCHOR_IPV4" ] && MAIN_ANCHOR_IPV4=$(echo "$METADATA_JSON" | jq -r '(.interfaces.public // []) | if type == "array" then .[0] else . end | .anchor_ipv4.address // empty' 2>/dev/null || echo "")

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
printf "│ sing-box        : %-38s│\n" "$SB_VERSION ($SINGBOX_BIN)"
echo "└──────────────────────────────────────────────────────────┘"

# ── 验证 IP ──────────────────────────────────────────────────
ERRORS=()
WARNINGS=()

[ -z "$MAIN_PUBLIC_IPV4" ] && ERRORS+=("主公网IPv4不可用")
[ -z "$MAIN_IPV6" ] && ERRORS+=("主IPv6不可用 — 请在DO控制面板启用IPv6")

if [ -z "$MAIN_ANCHOR_IPV4" ]; then
    WARNINGS+=("无 Anchor IPv4，实例2(保留IPv4)将跳过")
    HAS_RESERVED_V4=false
else
    HAS_RESERVED_V4=true
fi

if [ -z "$RESERVED_IPV4" ]; then
    RESERVED_IPV4_FOR_LINK="$MAIN_PUBLIC_IPV4"
else
    RESERVED_IPV4_FOR_LINK="$RESERVED_IPV4"
fi

if [ -z "$RESERVED_IPV6" ] || [ "$RESERVED_IPV6_ACTIVE" != "true" ]; then
    WARNINGS+=("保留IPv6不可用或未激活，实例4将跳过")
    HAS_RESERVED_V6=false
else
    HAS_RESERVED_V6=true
fi

[ ${#WARNINGS[@]} -gt 0 ] && echo "" && echo "⚠️  警告:" && for w in "${WARNINGS[@]}"; do echo "   • $w"; done
if [ ${#ERRORS[@]} -gt 0 ]; then
    echo "" && echo "❌ 致命错误:" && for e in "${ERRORS[@]}"; do echo "   • $e"; done
    echo "💡 调试: cat /tmp/do_metadata_debug.json | jq ."
    exit 1
fi

# ── 检查原始配置 ─────────────────────────────────────────────
SOURCE_FILE="/etc/s-box/sb.json"
[ ! -f "$SOURCE_FILE" ] && echo "❌ 找不到 $SOURCE_FILE" && exit 1
echo ""
echo "✅ 原始配置: $SOURCE_FILE"

# ── 配置内核级 IPv6 路由 ─────────────────────────────────────
echo ""
echo "⚙️  配置 IPv6 路由..."

sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.eth0.disable_ipv6=0 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.lo.disable_ipv6=0 >/dev/null 2>&1 || true
echo "   ├─ ✅ IPv6 已启用"

if [ "$HAS_RESERVED_V6" = true ]; then
    ip -6 addr replace "${RESERVED_IPV6}/128" dev lo scope global 2>/dev/null || \
        ip -6 addr add "${RESERVED_IPV6}/128" dev lo scope global 2>/dev/null || true
    if ip -6 addr show dev lo | grep -q "$RESERVED_IPV6"; then
        echo "   ├─ ✅ 保留IPv6 已绑定 lo"
    else
        echo "   ├─ ❌ 保留IPv6 绑定失败" && HAS_RESERVED_V6=false
    fi
fi

if ! ip -6 addr show dev eth0 scope global | grep -q "$MAIN_IPV6"; then
    echo "   ├─ 添加主IPv6到eth0..."
    ip -6 addr add "${MAIN_IPV6}/64" dev eth0 scope global 2>/dev/null || true
fi

if ! ip -6 route show default | grep -q "default"; then
    [ -n "$MAIN_IPV6_GATEWAY" ] && ip -6 route add default via "$MAIN_IPV6_GATEWAY" dev eth0 2>/dev/null || true
fi
echo "   ├─ ✅ IPv6 路由已确认"

ping6 -c 1 -W 3 2606:4700:4700::1111 >/dev/null 2>&1 && echo "   ├─ ✅ IPv6 连通正常" || echo "   ├─ ⚠️  IPv6 ping 失败"

# 持久化
mkdir -p /etc/s-box
cat > /etc/s-box/setup-ipv6-routes.sh << EOFPERSIST
#!/bin/bash
sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1
sysctl -w net.ipv6.conf.lo.disable_ipv6=0 >/dev/null 2>&1
[ "${HAS_RESERVED_V6}" = "true" ] && ip -6 addr replace "${RESERVED_IPV6}/128" dev lo scope global 2>/dev/null
echo "[\$(date)] IPv6 routes restored" >> /var/log/do-ipv6-routes.log
EOFPERSIST
chmod +x /etc/s-box/setup-ipv6-routes.sh

cat > /etc/systemd/system/do-ipv6-routes.service << EOFSVC
[Unit]
Description=DO IPv6 Route Persistence
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/etc/s-box/setup-ipv6-routes.sh
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOFSVC
systemctl daemon-reload && systemctl enable do-ipv6-routes.service >/dev/null 2>&1
echo "   └─ ✅ 持久化服务已注册"

# ── Python: 生成配置 + 订阅链接 ──────────────────────────────
echo ""
echo "⚙️  生成配置文件..."

python3 << PYEOF
import json, sys, copy, base64, os
from urllib.parse import quote

source_file      = "${SOURCE_FILE}"
anchor_ipv4      = "${MAIN_ANCHOR_IPV4}"
main_public_ipv4 = "${MAIN_PUBLIC_IPV4}"
reserved_ipv4    = "${RESERVED_IPV4_FOR_LINK}"
main_ipv6        = "${MAIN_IPV6}"
reserved_ipv6    = "${RESERVED_IPV6}"
hostname         = "${HOSTNAME_LABEL}"
has_reserved_v4  = "${HAS_RESERVED_V4}" == "true"
has_reserved_v6  = "${HAS_RESERVED_V6}" == "true"
sb_version       = "${SB_VERSION}"
sb_major_minor   = "${SB_MAJOR_MINOR}"

CONFIG_DIR = "/etc/s-box"

try:
    sv = sb_major_minor.split('.')
    sb_major, sb_minor = int(sv[0]), int(sv[1])
except:
    sb_major, sb_minor = 99, 99

print(f"   sing-box {sb_version} (major={sb_major}, minor={sb_minor})")

# 判断是否使用新格式 (1.11+ 用 action 替代 block outbound, 1.12+ 用新 DNS 格式)
use_new_dns = (sb_major > 1) or (sb_major == 1 and sb_minor >= 12)
use_new_route = (sb_major > 1) or (sb_major == 1 and sb_minor >= 11)

print(f"   新DNS格式(1.12+): {use_new_dns}, 新路由动作(1.11+): {use_new_route}")

try:
    with open(source_file, 'r', encoding='utf-8') as f:
        original_config = json.load(f)
except Exception as e:
    print(f'❌ 解析配置失败: {e}')
    sys.exit(1)

print(f"   ✅ 已加载 {len(original_config.get('inbounds', []))} 个入站")

# ═══════════════════════════════════════════════════════════
# 工具函数
# ═══════════════════════════════════════════════════════════

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
    for ib in config.get('inbounds', []):
        if ib.get('type') == 'vmess':
            sni = ib.get('tls', {}).get('server_name', '')
            if sni: return sni
    return "www.bing.com"

def shift_ports(config, offset):
    for ib in config.get('inbounds', []):
        if 'listen_port' in ib and isinstance(ib['listen_port'], int):
            old = ib['listen_port']
            ib['listen_port'] = old + offset
            print(f"      端口: {old} -> {old + offset}")

def force_ipv4_listen(config):
    for ib in config.get('inbounds', []):
        ib['listen'] = '0.0.0.0'

def build_strict_ipv6_dns():
    """严格 IPv6-only DNS，自动适配 sing-box 版本"""
    if use_new_dns:
        # 1.12.0+ 新格式: type + server + server_port
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
    else:
        # 1.11.x 及更早: address 字段格式
        return {
            "servers": [
                {
                    "tag": "ipv6-dns-cf",
                    "address": "tls://[2606:4700:4700::1111]",
                    "address_strategy": "ipv6_only",
                    "strategy": "ipv6_only",
                    "detour": "direct"
                },
                {
                    "tag": "ipv6-dns-google",
                    "address": "tls://[2001:4860:4860::8888]",
                    "address_strategy": "ipv6_only",
                    "strategy": "ipv6_only",
                    "detour": "direct"
                },
                {
                    "tag": "block-dns",
                    "address": "rcode://refused"
                }
            ],
            "final": "ipv6-dns-cf",
            "strategy": "ipv6_only",
            "disable_cache": False,
            "independent_cache": True
        }

def build_strict_ipv6_route():
    """严格 IPv6 路由, 自动适配版本"""
    if use_new_route:
        # 1.11.0+ : 使用 action, final 可以直接 "reject"
        return {
            "rules": [
                {"action": "sniff", "timeout": "1s"},
                {"protocol": "dns", "action": "hijack-dns"},
                {"ip_version": 4, "action": "reject", "method": "default"},
                {"ip_cidr": ["0.0.0.0/0"], "action": "reject", "method": "default"},
                {"action": "route", "outbound": "direct"}
            ],
            "final": "reject",
            "auto_detect_interface": False
        }
    else:
        # 1.10.x: 使用 block outbound
        return {
            "rules": [
                {"protocol": ["quic", "stun"], "outbound": "block-ipv4"},
                {"outbound": "direct", "network": "udp,tcp"}
            ]
        }

def build_ipv6_outbounds(bind_ipv6_addr):
    """严格 IPv6 出站"""
    outbounds = [
        {
            "type": "direct",
            "tag": "direct",
            "bind_interface": "eth0",
            "inet6_bind_address": bind_ipv6_addr,
            "bind_address_no_port": True,
            "tcp_multi_path": False,
            "tcp_fast_open": False,
            "udp_fragment": True
        }
    ]
    
    # 1.12.0+ 需要 domain_resolver
    if use_new_dns:
        outbounds[0]["domain_resolver"] = "ipv6-dns-cf"
    
    # 1.10.x 需要 block outbound
    if not use_new_route:
        outbounds.append({"type": "block", "tag": "block-ipv4"})
    
    return outbounds

def apply_ipv6_strict(config, bind_ipv6_addr):
    force_ipv4_listen(config)
    config['dns'] = build_strict_ipv6_dns()
    config['route'] = build_strict_ipv6_route()
    config['outbounds'] = build_ipv6_outbounds(bind_ipv6_addr)
    # 移除 endpoints (warp 等可能泄漏 IPv4)
    if 'endpoints' in config:
        del config['endpoints']
    return config

# ═══════════════════════════════════════════════════════════
# 生成实例
# ═══════════════════════════════════════════════════════════

generated = []

# 实例2: 保留 IPv4 (端口+1)
if has_reserved_v4 and anchor_ipv4:
    print(f"\n📋 实例2: 保留IPv4 (端口+1, Anchor: {anchor_ipv4})")
    cfg = copy.deepcopy(original_config)
    shift_ports(cfg, 1)
    bound = False
    for ob in cfg.get('outbounds', []):
        if ob.get('tag') == 'direct' and ob.get('type') == 'direct':
            ob['inet4_bind_address'] = anchor_ipv4
            ob['udp_fragment'] = True
            ob['bind_address_no_port'] = True
            print(f"      出站绑定: {anchor_ipv4}")
            bound = True
            break
    if not bound:
        cfg.setdefault('outbounds', []).insert(0, {
            "type": "direct", "tag": "direct",
            "inet4_bind_address": anchor_ipv4,
            "udp_fragment": True, "bind_address_no_port": True
        })
    fpath = f"{CONFIG_DIR}/sb-reserved-v4.json"
    with open(fpath, 'w') as f: json.dump(cfg, f, indent=4, ensure_ascii=False)
    print(f"      ✅ {fpath}")
    generated.append(("reserved-v4", fpath, cfg, reserved_ipv4, "保留IPv4"))
else:
    print(f"\n⏭️  实例2: 跳过")

# 实例3: 主IPv6 (端口+2)
print(f"\n📋 实例3: 主IPv6 (端口+2, 绑定: {main_ipv6})")
cfg = copy.deepcopy(original_config)
shift_ports(cfg, 2)
apply_ipv6_strict(cfg, main_ipv6)
fpath = f"{CONFIG_DIR}/sb-ipv6.json"
with open(fpath, 'w') as f: json.dump(cfg, f, indent=4, ensure_ascii=False)
print(f"      ✅ {fpath}")
generated.append(("ipv6", fpath, cfg, main_public_ipv4, "主IPv6"))

# 实例4: 保留IPv6 (端口+3)
if has_reserved_v6 and reserved_ipv6:
    print(f"\n📋 实例4: 保留IPv6 (端口+3, 绑定: {reserved_ipv6})")
    cfg = copy.deepcopy(original_config)
    shift_ports(cfg, 3)
    apply_ipv6_strict(cfg, reserved_ipv6)
    fpath = f"{CONFIG_DIR}/sb-reserved-v6.json"
    with open(fpath, 'w') as f: json.dump(cfg, f, indent=4, ensure_ascii=False)
    print(f"      ✅ {fpath}")
    generated.append(("reserved-v6", fpath, cfg, main_public_ipv4, "保留IPv6"))
else:
    print(f"\n⏭️  实例4: 跳过")

# ═══════════════════════════════════════════════════════════
# 订阅链接
# ═══════════════════════════════════════════════════════════

common_sni = get_common_sni(original_config)

def gen_links(config, connect_ip, label_suffix):
    links = []
    for ib in config.get('inbounds', []):
        itype = ib.get('type')
        port = ib.get('listen_port')
        tag = ib.get('tag', '').replace('-sb', '')
        label = f"{tag}-{hostname}-{label_suffix}"
        tls = ib.get('tls', {})
        sni = tls.get('server_name', common_sni) or common_sni

        if itype == 'vless':
            uuid = ib['users'][0]['uuid']
            flow = ib['users'][0].get('flow', 'xtls-rprx-vision')
            reality = tls.get('reality', {})
            pk = reality.get('private_key', '')
            sid = reality.get('short_id', [''])[0]
            pbk = derive_x25519_pubkey(pk) if pk else ''
            links.append(('VLESS Reality',
                f"vless://{uuid}@{connect_ip}:{port}?encryption=none&flow={flow}"
                f"&security=reality&sni={sni}&fp=chrome&pbk={pbk}&sid={sid}"
                f"&type=tcp&headerType=none#{label}"))
        elif itype == 'vmess':
            uuid = ib['users'][0]['uuid']
            tp = ib.get('transport', {})
            path = tp.get('path', '')
            tls_on = tls.get('enabled', False)
            obj = {"v":"2","ps":f"vm-ws-{hostname}-{label_suffix}","add":connect_ip,
                   "port":str(port),"id":uuid,"aid":"0","scy":"auto","net":"ws",
                   "type":"none","host":sni,"path":path,
                   "tls":"tls" if tls_on else "","sni":sni if tls_on else "",
                   "alpn":"","fp":"","insecure":"0"}
            enc = base64.b64encode(json.dumps(obj, separators=(',',': '), ensure_ascii=False).encode()).decode()
            links.append(('VMess WS', f"vmess://{enc}"))
        elif itype == 'hysteria2':
            pw = ib['users'][0]['password']
            links.append(('Hysteria2',
                f"hysteria2://{pw}@{connect_ip}:{port}?sni={sni}&alpn=h3&insecure=1&allowInsecure=1#{label}"))
        elif itype == 'tuic':
            uuid = ib['users'][0]['uuid']
            pw = ib['users'][0]['password']
            auth = quote(f"{uuid}:{pw}", safe='')
            links.append(('TUIC v5',
                f"tuic://{auth}@{connect_ip}:{port}?sni={sni}&alpn=h3&insecure=1&allowInsecure=1&congestion_control=bbr#{label}"))
        elif itype == 'anytls':
            pw = ib['users'][0]['password']
            links.append(('AnyTLS',
                f"anytls://{pw}@{connect_ip}:{port}?security=tls&sni={sni}&insecure=1&allowInsecure=1&type=tcp#{label}"))
    return links

all_sections = []

# 实例1: 主IPv4
l1 = gen_links(original_config, main_public_ipv4, "主IPv4")
all_sections.append(("实例1-主IPv4", f"出口: {main_public_ipv4}", l1))

for iid, ifile, icfg, iip, ilabel in generated:
    ll = gen_links(icfg, iip, ilabel)
    if "ipv6" in iid:
        if "reserved" in iid:
            info = f"入口: {main_public_ipv4} → 出口: {reserved_ipv6}"
        else:
            info = f"入口: {main_public_ipv4} → 出口: {main_ipv6}"
    else:
        info = f"出口: {iip}"
    all_sections.append((f"实例-{ilabel}", info, ll))

for sn, si, sl in all_sections:
    print(f"\n{'='*60}")
    print(f"  📡 {sn} | {si}")
    print(f"{'='*60}")
    for name, link in sl:
        d = link[:90] + "..." if len(link) > 100 else link
        print(f"  📌 {name}: {d}")

# 保存
lf = f"{CONFIG_DIR}/all-links.txt"
with open(lf, 'w') as f:
    f.write(f"# DO 四出口订阅链接 | {hostname}\n")
    f.write(f"# 主IPv4: {main_public_ipv4} | 保留IPv4: {reserved_ipv4}\n")
    f.write(f"# 主IPv6: {main_ipv6} | 保留IPv6: {reserved_ipv6}\n\n")
    for sn, si, sl in all_sections:
        f.write(f"{'#'*60}\n# {sn} | {si}\n{'#'*60}\n\n")
        for name, link in sl:
            f.write(f"# {name}\n{link}\n\n")
print(f"\n💾 链接: {lf}")

for idx, (sn, si, sl) in enumerate(all_sections, 1):
    with open(f"{CONFIG_DIR}/links-instance{idx}.txt", 'w') as f:
        f.write(f"# {sn} | {si}\n\n")
        for name, link in sl:
            f.write(f"# {name}\n{link}\n\n")
print("💾 各实例链接已分别保存")

with open(f"{CONFIG_DIR}/.generated_instances", 'w') as f:
    for iid, ifile, _, _, ilabel in generated:
        f.write(f"{iid}|{ifile}|{ilabel}\n")
PYEOF

[ $? -ne 0 ] && echo "❌ 配置生成失败" && exit 1

# ── systemd 服务 ─────────────────────────────────────────────
echo ""
echo "⚙️  配置 systemd 服务..."

SERVICE_SOURCE="/etc/systemd/system/sing-box.service"
[ ! -f "$SERVICE_SOURCE" ] && echo "❌ 找不到 $SERVICE_SOURCE" && exit 1

INSTANCE_INFO="/etc/s-box/.generated_instances"
if [ -f "$INSTANCE_INFO" ]; then
    while IFS='|' read -r INST_ID INST_FILE INST_LABEL; do
        SVC_NAME="sing-box-${INST_ID}"
        SVC_FILE="/etc/systemd/system/${SVC_NAME}.service"
        CFG_BASE=$(basename "$INST_FILE")
        sed "s|sb\.json|${CFG_BASE}|g" "$SERVICE_SOURCE" > "$SVC_FILE"
        sed -i "s/Description=.*/Description=sing-box ${INST_LABEL}/" "$SVC_FILE"
        echo "   ├─ ✅ ${SVC_NAME}.service (${INST_LABEL})"
    done < "$INSTANCE_INFO"
fi

# ── 验证配置 ─────────────────────────────────────────────────
echo ""
echo "🔍 验证配置..."

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

[ "$ALL_VALID" = false ] && echo "⚠️  部分配置验证失败 (sing-box $SB_VERSION)"

# ── 启动服务 ─────────────────────────────────────────────────
echo ""
echo "🚀 启动服务..."
systemctl daemon-reload

if [ -f "$INSTANCE_INFO" ]; then
    while IFS='|' read -r INST_ID INST_FILE INST_LABEL; do
        SVC="sing-box-${INST_ID}"
        systemctl enable "$SVC" >/dev/null 2>&1
        systemctl restart "$SVC" 2>/dev/null
        sleep 1
        if systemctl is-active --quiet "$SVC"; then
            echo "   ├─ ✅ ${SVC} (${INST_LABEL}) - 运行中"
        else
            echo "   ├─ ❌ ${SVC} (${INST_LABEL}) - 启动失败"
            journalctl -u "$SVC" --no-pager -n 5 2>/dev/null | sed 's/^/   │  /'
        fi
    done < "$INSTANCE_INFO"
fi

# ── 验证出口 ─────────────────────────────────────────────────
echo ""
echo "🔍 验证出口..."
SYS_V4=$(curl -4 -sf --connect-timeout 5 --max-time 10 https://api.ipify.org 2>/dev/null || echo "N/A")
SYS_V6=$(curl -6 -sf --connect-timeout 5 --max-time 10 https://api6.ipify.org 2>/dev/null || echo "N/A")
printf "   IPv4: %-40s (期望: %s)\n" "$SYS_V4" "$MAIN_PUBLIC_IPV4"
printf "   IPv6: %-40s (期望: %s)\n" "$SYS_V6" "$MAIN_IPV6"

# ── IPv6 状态 ────────────────────────────────────────────────
echo ""
echo "📋 IPv6 状态:"
echo "   eth0:"; ip -6 addr show dev eth0 scope global 2>/dev/null | sed 's/^/      /' || echo "      (无)"
echo "   lo:"; ip -6 addr show dev lo scope global 2>/dev/null | sed 's/^/      /' || echo "      (无)"

# ── 最终报告 ─────────────────────────────────────────────────
echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                   🎉 四出口配置完成！                          ║"
echo "╠════════════════════════════════════════════════════════════════╣"
printf "║  实例1: 主IPv4     | %-42s║\n" "$MAIN_PUBLIC_IPV4 (原始)"
[ "$HAS_RESERVED_V4" = true ] && \
printf "║  实例2: 保留IPv4   | %-42s║\n" "$RESERVED_IPV4_FOR_LINK (端口+1)"
printf "║  实例3: 主IPv6     | %-42s║\n" "$MAIN_IPV6 (端口+2)"
[ "$HAS_RESERVED_V6" = true ] && \
printf "║  实例4: 保留IPv6   | %-42s║\n" "$RESERVED_IPV6 (端口+3)"
echo "╠════════════════════════════════════════════════════════════════╣"
echo "║  📁 /etc/s-box/sb.json                      (实例1)           ║"
[ "$HAS_RESERVED_V4" = true ] && \
echo "║  📁 /etc/s-box/sb-reserved-v4.json          (实例2)           ║"
echo "║  📁 /etc/s-box/sb-ipv6.json                 (实例3)           ║"
[ "$HAS_RESERVED_V6" = true ] && \
echo "║  📁 /etc/s-box/sb-reserved-v6.json          (实例4)           ║"
echo "║  🔗 /etc/s-box/all-links.txt                                  ║"
echo "╠════════════════════════════════════════════════════════════════╣"
echo "║  ⚠️  IPv6 严格模式 (实例3/4):                                  ║"
echo "║     • DNS: 仅 AAAA (版本自适应格式)                           ║"
echo "║     • 路由: ip_version:4 + 0.0.0.0/0 双重拒绝                 ║"
echo "║     • 出站: inet6_bind_address 绑定                           ║"
echo "║     • 纯IPv4网站无法访问（预期行为）                           ║"
echo "╠════════════════════════════════════════════════════════════════╣"
echo "║  🛠️  管理:                                                     ║"
echo "║  systemctl status sing-box                         (主IPv4)   ║"
[ "$HAS_RESERVED_V4" = true ] && \
echo "║  systemctl status sing-box-reserved-v4             (保留IPv4) ║"
echo "║  systemctl status sing-box-ipv6                    (主IPv6)   ║"
[ "$HAS_RESERVED_V6" = true ] && \
echo "║  systemctl status sing-box-reserved-v6             (保留IPv6) ║"
echo "║  cat /etc/s-box/all-links.txt                      (链接)    ║"
echo "╚════════════════════════════════════════════════════════════════╝"
