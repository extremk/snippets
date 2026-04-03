#!/bin/bash
# ====================================================
# DigitalOcean 四出口一键配置脚本 (适配 sing-box-yg)
# 兼容 sing-box 1.11.x / 1.12.x / 1.13.x / sb.sh 管理脚本
#
# 严格协议隔离:
#   实例1: 主IPv4      (主端口)   IPv4-only (修改sb.json)
#   实例2: 保留IPv4    (端口+1)   IPv4-only
#   实例3: 主IPv6      (端口+2)   IPv6-only
#   实例4: 保留IPv6    (端口+3)   IPv6-only
# ====================================================

set -euo pipefail
[ "$EUID" -ne 0 ] && echo "❌ 请使用 root 运行" && exit 1

echo "============================================="
echo "🚀 DigitalOcean 四出口配置 (严格协议隔离)"
echo "============================================="

for cmd in curl jq python3; do
    command -v "$cmd" &>/dev/null || { apt-get update -qq && apt-get install -y -qq "$cmd" 2>/dev/null || { echo "❌ 无法安装 $cmd"; exit 1; }; }
done
python3 -c "from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey" 2>/dev/null || {
    pip3 install cryptography -q 2>/dev/null || apt-get install -y -qq python3-cryptography 2>/dev/null || true
}

if [ -x /etc/s-box/sing-box ]; then SINGBOX_BIN="/etc/s-box/sing-box"
elif command -v sing-box &>/dev/null; then SINGBOX_BIN=$(command -v sing-box)
else echo "❌ 找不到 sing-box"; exit 1; fi

SB_VERSION=$($SINGBOX_BIN version 2>/dev/null | awk '/version/{print $NF}' || echo "0.0.0")
SB_MM=$($SINGBOX_BIN version 2>/dev/null | awk '/version/{print $NF}' | cut -d'.' -f1,2 || echo "0.0")
echo "📌 sing-box: $SINGBOX_BIN (v$SB_VERSION)"

echo "" && echo "🔄 停止所有实例..."
for svc in sing-box sing-box-reserved-v4 sing-box-ipv6 sing-box-reserved-v6 sing-box-reserved; do
    systemctl stop "$svc" 2>/dev/null || true
    [[ "$svc" != "sing-box" ]] && systemctl disable "$svc" 2>/dev/null || true
done
pkill -9 -f "sing-box" 2>/dev/null || true; sleep 2
echo "   └─ ✅ 已停止"

echo "" && echo "🔍 查询 DigitalOcean 元数据..."
METADATA_JSON=$(curl -sf http://169.254.169.254/metadata/v1.json 2>/dev/null) || { echo "❌ 元数据不可用"; exit 1; }
echo "$METADATA_JSON" > /tmp/do_metadata_debug.json

MAIN_PUBLIC_IPV4=$(curl -sf http://169.254.169.254/metadata/v1/interfaces/public/0/ipv4/address 2>/dev/null || echo "")
MAIN_ANCHOR_IPV4=$(curl -sf http://169.254.169.254/metadata/v1/interfaces/public/0/anchor_ipv4/address 2>/dev/null || echo "")
ANCHOR_GATEWAY=$(curl -sf http://169.254.169.254/metadata/v1/interfaces/public/0/anchor_ipv4/gateway 2>/dev/null || echo "")
RESERVED_IPV4=$(curl -sf http://169.254.169.254/metadata/v1/reserved_ip/ipv4/ip_address 2>/dev/null || echo "")
MAIN_IPV6=$(curl -sf http://169.254.169.254/metadata/v1/interfaces/public/0/ipv6/address 2>/dev/null || echo "")
MAIN_IPV6_GATEWAY=$(curl -sf http://169.254.169.254/metadata/v1/interfaces/public/0/ipv6/gateway 2>/dev/null || echo "")
[ -z "$MAIN_IPV6" ] && MAIN_IPV6=$(echo "$METADATA_JSON" | jq -r '(.interfaces.public // []) | if type == "array" then .[0] else . end | .ipv6 | if type == "object" then .address elif type == "array" then .[0].address else empty end // empty' 2>/dev/null || echo "")
[ -z "$MAIN_IPV6" ] && MAIN_IPV6=$(ip -6 addr show dev eth0 scope global | grep -v "deprecated\|temporary" | grep "inet6" | head -1 | awk '{print $2}' | cut -d'/' -f1 || echo "")
[ -z "$MAIN_IPV6_GATEWAY" ] && MAIN_IPV6_GATEWAY=$(echo "$METADATA_JSON" | jq -r '(.interfaces.public // []) | if type == "array" then .[0] else . end | .ipv6 | if type == "object" then .gateway elif type == "array" then .[0].gateway else empty end // empty' 2>/dev/null || echo "")
[ -z "$MAIN_IPV6_GATEWAY" ] && MAIN_IPV6_GATEWAY=$(ip -6 route show default dev eth0 2>/dev/null | head -1 | awk '{print $3}' || echo "")
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
printf "│ 主公网IPv4      : %-38s│\n" "${MAIN_PUBLIC_IPV4:-❌}"
printf "│ Anchor IPv4     : %-38s│\n" "${MAIN_ANCHOR_IPV4:-⚠️}"
printf "│ Anchor Gateway  : %-38s│\n" "${ANCHOR_GATEWAY:-⚠️}"
printf "│ 保留 IPv4       : %-38s│\n" "${RESERVED_IPV4:-⚠️}"
printf "│ 主 IPv6         : %-38s│\n" "${MAIN_IPV6:-❌}"
printf "│ IPv6 网关       : %-38s│\n" "${MAIN_IPV6_GATEWAY:-⚠️}"
printf "│ 保留 IPv6       : %-38s│\n" "${RESERVED_IPV6:-⚠️}"
printf "│ 保留IPv6激活    : %-38s│\n" "${RESERVED_IPV6_ACTIVE:-⚠️}"
printf "│ 标签/版本       : %-38s│\n" "$HOSTNAME_LABEL / v$SB_VERSION"
echo "└──────────────────────────────────────────────────────────┘"

ERRORS=(); WARNINGS=()
[ -z "$MAIN_PUBLIC_IPV4" ] && ERRORS+=("主IPv4不可用")
[ -z "$MAIN_IPV6" ] && ERRORS+=("主IPv6不可用")
if [ -z "$MAIN_ANCHOR_IPV4" ]; then WARNINGS+=("无Anchor IPv4，跳过实例2"); HAS_RV4=false; else HAS_RV4=true; fi
[ -z "$RESERVED_IPV4" ] && RESERVED_IPV4_LINK="$MAIN_PUBLIC_IPV4" || RESERVED_IPV4_LINK="$RESERVED_IPV4"
if [ -z "$RESERVED_IPV6" ] || [ "$RESERVED_IPV6_ACTIVE" != "true" ]; then WARNINGS+=("保留IPv6不可用，跳过实例4"); HAS_RV6=false; else HAS_RV6=true; fi
[ ${#WARNINGS[@]} -gt 0 ] && echo "" && for w in "${WARNINGS[@]}"; do echo "⚠️  $w"; done
if [ ${#ERRORS[@]} -gt 0 ]; then echo "" && for e in "${ERRORS[@]}"; do echo "❌ $e"; done; exit 1; fi

SOURCE_FILE="/etc/s-box/sb.json"
[ ! -f "$SOURCE_FILE" ] && echo "❌ 找不到 $SOURCE_FILE" && exit 1
[ ! -f /etc/s-box/sb.json.original ] && cp "$SOURCE_FILE" /etc/s-box/sb.json.original && echo "" && echo "📦 已备份 → sb.json.original"
echo "" && echo "✅ 配置: $SOURCE_FILE"

echo "" && echo "⚙️  配置 IPv6 路由..."
for ns in all default eth0 lo; do sysctl -w net.ipv6.conf.$ns.disable_ipv6=0 >/dev/null 2>&1; done
echo "   ├─ ✅ IPv6 已启用"
if [ "$HAS_RV6" = true ]; then
    ip -6 addr replace "${RESERVED_IPV6}/128" dev lo scope global 2>/dev/null || ip -6 addr add "${RESERVED_IPV6}/128" dev lo scope global 2>/dev/null || true
    ip -6 addr show dev lo | grep -q "$RESERVED_IPV6" && echo "   ├─ ✅ 保留IPv6 绑定 lo" || { echo "   ├─ ❌ 绑定失败"; HAS_RV6=false; }
fi
ip -6 addr show dev eth0 scope global | grep -q "$MAIN_IPV6" || ip -6 addr add "${MAIN_IPV6}/64" dev eth0 scope global 2>/dev/null || true
ip -6 route show default | grep -q "default" || { [ -n "$MAIN_IPV6_GATEWAY" ] && ip -6 route add default via "$MAIN_IPV6_GATEWAY" dev eth0 2>/dev/null || true; }
echo "   ├─ ✅ IPv6 路由确认"
ping6 -c1 -W3 2606:4700:4700::1111 >/dev/null 2>&1 && echo "   ├─ ✅ IPv6 连通" || echo "   ├─ ⚠️  IPv6 ping 失败"
mkdir -p /etc/s-box
cat > /etc/s-box/setup-ipv6-routes.sh << 'EOFP'
#!/bin/bash
for ns in all default lo; do sysctl -w net.ipv6.conf.$ns.disable_ipv6=0 >/dev/null 2>&1; done
EOFP
[ "$HAS_RV6" = true ] && echo "ip -6 addr replace \"${RESERVED_IPV6}/128\" dev lo scope global 2>/dev/null || true" >> /etc/s-box/setup-ipv6-routes.sh
chmod +x /etc/s-box/setup-ipv6-routes.sh
cat > /etc/systemd/system/do-ipv6-routes.service << EOF
[Unit]
Description=DO IPv6 Routes
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/etc/s-box/setup-ipv6-routes.sh
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload && systemctl enable do-ipv6-routes.service >/dev/null 2>&1
echo "   └─ ✅ 持久化已注册"

# ── Python ───────────────────────────────────────────────────
echo "" && echo "⚙️  生成配置（兼容 sb.sh）..."

python3 << PYEOF
import json, sys, copy, base64, os
from urllib.parse import quote

source_file      = "${SOURCE_FILE}"
anchor_ipv4      = "${MAIN_ANCHOR_IPV4}"
main_public_ipv4 = "${MAIN_PUBLIC_IPV4}"
reserved_ipv4    = "${RESERVED_IPV4_LINK}"
main_ipv6        = "${MAIN_IPV6}"
reserved_ipv6    = "${RESERVED_IPV6}"
hostname         = "${HOSTNAME_LABEL}"
has_rv4          = "${HAS_RV4}" == "true"
has_rv6          = "${HAS_RV6}" == "true"
sb_mm            = "${SB_MM}"
CONFIG_DIR       = "/etc/s-box"

try:
    sv = sb_mm.split('.'); sb_major, sb_minor = int(sv[0]), int(sv[1])
except:
    sb_major, sb_minor = 99, 99

use_new_dns   = (sb_major > 1) or (sb_major == 1 and sb_minor >= 12)
use_new_route = (sb_major > 1) or (sb_major == 1 and sb_minor >= 11)

print(f"   v{sb_mm} | 新DNS: {use_new_dns} | 新路由: {use_new_route}")

with open(source_file, 'r') as f:
    original_config = json.load(f)
print(f"   ✅ {len(original_config.get('inbounds', []))} 个入站")

# ═══════════════════════════════════════════════════════════
def derive_x25519_pubkey(pk):
    try:
        from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
        from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
        pad = pk + '=' * (-len(pk) % 4); raw = base64.urlsafe_b64decode(pad)
        priv = X25519PrivateKey.from_private_bytes(raw)
        return base64.urlsafe_b64encode(priv.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)).rstrip(b'=').decode()
    except: return ""

def get_common_sni(cfg):
    for ib in cfg.get('inbounds', []):
        if ib.get('type') == 'vmess':
            s = ib.get('tls', {}).get('server_name', '')
            if s: return s
    return "www.bing.com"

def shift_ports(cfg, offset):
    for ib in cfg.get('inbounds', []):
        if 'listen_port' in ib and isinstance(ib['listen_port'], int):
            old = ib['listen_port']; ib['listen_port'] = old + offset
            print(f"      端口: {old} -> {old + offset}")

# ═══════════════════════════════════════════════════════════
# 实例1: 在原始 sb.json 上注入严格 IPv4 约束
#
# 甬哥 sb.sh 的 jq 查询路径（sb11.json 格式 / 1.11+）：
#   .outbounds[0]                → direct
#   .outbounds[1]                → socks-out
#   .route.rules[0]              → sniff action
#   .route.rules[1]              → resolve prefer_ipv4
#   .route.rules[2]              → resolve prefer_ipv6
#   .route.rules[3]              → socks-out 分流
#   .route.rules[4]              → warp-out 分流
#   .route.rules[5]              → direct final
#
# 策略：
#   1. DNS: 注入全局 strategy: ipv4_only（新格式需替换整个dns块）
#   2. 路由: 在最后一条 direct 规则之前插入 IPv6 reject
#      这样 rules[0]-[4] 的索引保持不变，甬哥的 sed/jq 正常工作
#   3. 出站: 保留原始 outbounds 结构不变
#   4. 移除 endpoints (warp) 防 IPv6 泄漏
#   5. 新格式需要 default_domain_resolver
# ═══════════════════════════════════════════════════════════

def inject_ipv4_strict(cfg):
    """在原始结构上注入 IPv4 约束，保持甬哥脚本兼容"""

    # --- DNS ---
    if use_new_dns:
        # 1.12+: 必须用新格式，完全替换 dns
        # 但甬哥脚本不直接读 dns 块，所以安全
        cfg['dns'] = {
            "servers": [
                {"tag": "ipv4-dns-cf", "type": "tls", "server": "1.1.1.1", "server_port": 853},
                {"tag": "ipv4-dns-google", "type": "tls", "server": "8.8.8.8", "server_port": 853}
            ],
            "final": "ipv4-dns-cf",
            "strategy": "ipv4_only",
            "disable_cache": False,
            "independent_cache": True
        }
    else:
        # 1.10/1.11: 在现有 dns 上注入
        if 'dns' not in cfg: cfg['dns'] = {}
        cfg['dns']['strategy'] = 'ipv4_only'

    # --- Route: 在最后一条规则之前插入 IPv6 reject ---
    rules = cfg.get('route', {}).get('rules', [])

    # 先清除之前可能注入的 reject 规则（幂等性）
    rules = [r for r in rules if not (
        (r.get('ip_version') == 6 and r.get('action') == 'reject') or
        (r.get('ip_cidr') == ['::/0'] and r.get('action') == 'reject')
    )]

    if use_new_route:
        # 在最后一条规则之前插入（最后一条通常是 outbound: direct）
        reject_v6 = {"ip_version": 6, "action": "reject", "method": "default"}
        reject_v6_cidr = {"ip_cidr": ["::/0"], "action": "reject", "method": "default"}

        if len(rules) > 0:
            rules.insert(len(rules) - 1, reject_v6)
            rules.insert(len(rules) - 1, reject_v6_cidr)
        else:
            rules.append(reject_v6)
            rules.append(reject_v6_cidr)

    cfg['route']['rules'] = rules

    # 1.12+ 需要 default_domain_resolver
    if use_new_dns:
        cfg['route']['default_domain_resolver'] = {"server": "ipv4-dns-cf"}

    # --- 移除 endpoints (warp) 防 IPv6 泄漏 ---
    cfg.pop('endpoints', None)

    # --- 清除路由中引用 warp-out 的规则（因为 endpoints 已删除）---
    new_rules = []
    for r in cfg['route']['rules']:
        ob = r.get('outbound', '')
        if ob in ('warp-out',):
            # 保留规则结构但改为指向 direct，避免行号变化
            r['outbound'] = 'direct'
        new_rules.append(r)
    cfg['route']['rules'] = new_rules

    return cfg


# ═══════════════════════════════════════════════════════════
# 副实例: 完全重建（不需要兼容甬哥脚本）
# ═══════════════════════════════════════════════════════════

def build_clean_ipv4(cfg, bind_v4):
    if use_new_dns:
        cfg['dns'] = {
            "servers": [
                {"tag": "ipv4-dns-cf", "type": "tls", "server": "1.1.1.1", "server_port": 853},
                {"tag": "ipv4-dns-google", "type": "tls", "server": "8.8.8.8", "server_port": 853}
            ],
            "final": "ipv4-dns-cf", "strategy": "ipv4_only",
            "disable_cache": False, "independent_cache": True
        }
    else:
        cfg['dns'] = {
            "servers": [
                {"tag": "ipv4-dns-cf", "address": "tls://1.1.1.1", "address_strategy": "ipv4_only", "strategy": "ipv4_only", "detour": "direct"},
            ],
            "final": "ipv4-dns-cf", "strategy": "ipv4_only",
            "disable_cache": False, "independent_cache": True
        }
    if use_new_route:
        route = {"rules": [
            {"action": "sniff", "timeout": "1s"}, {"protocol": "dns", "action": "hijack-dns"},
            {"ip_version": 6, "action": "reject", "method": "default"},
            {"ip_cidr": ["::/0"], "action": "reject", "method": "default"}
        ], "final": "direct", "auto_detect_interface": False}
        if use_new_dns: route["default_domain_resolver"] = {"server": "ipv4-dns-cf"}
        cfg['route'] = route
    direct_ob = {"type": "direct", "tag": "direct", "bind_interface": "eth0",
        "inet4_bind_address": bind_v4, "bind_address_no_port": True,
        "tcp_multi_path": False, "tcp_fast_open": False, "udp_fragment": True}
    if use_new_dns: direct_ob["domain_resolver"] = "ipv4-dns-cf"
    cfg['outbounds'] = [direct_ob]
    cfg.pop('endpoints', None)
    return cfg

def build_clean_ipv6(cfg, bind_v6):
    for ib in cfg.get('inbounds', []): ib['listen'] = '0.0.0.0'
    if use_new_dns:
        cfg['dns'] = {
            "servers": [
                {"tag": "ipv6-dns-cf", "type": "tls", "server": "2606:4700:4700::1111", "server_port": 853},
                {"tag": "ipv6-dns-google", "type": "tls", "server": "2001:4860:4860::8888", "server_port": 853}
            ],
            "final": "ipv6-dns-cf", "strategy": "ipv6_only",
            "disable_cache": False, "independent_cache": True
        }
    else:
        cfg['dns'] = {
            "servers": [
                {"tag": "ipv6-dns-cf", "address": "tls://[2606:4700:4700::1111]", "address_strategy": "ipv6_only", "strategy": "ipv6_only", "detour": "direct"},
            ],
            "final": "ipv6-dns-cf", "strategy": "ipv6_only",
            "disable_cache": False, "independent_cache": True
        }
    if use_new_route:
        route = {"rules": [
            {"action": "sniff", "timeout": "1s"}, {"protocol": "dns", "action": "hijack-dns"},
            {"ip_version": 4, "action": "reject", "method": "default"},
            {"ip_cidr": ["0.0.0.0/0"], "action": "reject", "method": "default"}
        ], "final": "direct", "auto_detect_interface": False}
        if use_new_dns: route["default_domain_resolver"] = {"server": "ipv6-dns-cf"}
        cfg['route'] = route
    direct_ob = {"type": "direct", "tag": "direct", "bind_interface": "eth0",
        "inet6_bind_address": bind_v6, "bind_address_no_port": True,
        "tcp_multi_path": False, "tcp_fast_open": False, "udp_fragment": True}
    if use_new_dns: direct_ob["domain_resolver"] = "ipv6-dns-cf"
    cfg['outbounds'] = [direct_ob]
    cfg.pop('endpoints', None)
    return cfg

# ═══════════════════════════════════════════════════════════
generated = []

# 实例1
print(f"\n📋 实例1: 主IPv4 (注入IPv4约束，保留原始结构)")
cfg1 = copy.deepcopy(original_config)
inject_ipv4_strict(cfg1)
fp1 = f"{CONFIG_DIR}/sb.json"
with open(fp1, 'w') as f: json.dump(cfg1, f, indent=4, ensure_ascii=False)
print(f"      ✅ {fp1}")
generated.append(("main-v4", fp1, cfg1, main_public_ipv4, "主IPv4", "ipv4", main_public_ipv4))

# 同步 sb10/sb11
for sf in [f"{CONFIG_DIR}/sb10.json", f"{CONFIG_DIR}/sb11.json"]:
    if os.path.exists(sf):
        try:
            with open(sf, 'r') as f: scfg = json.load(f)
            inject_ipv4_strict(scfg)
            with open(sf, 'w') as f: json.dump(scfg, f, indent=4, ensure_ascii=False)
            print(f"      ✅ 同步 {os.path.basename(sf)}")
        except Exception as e:
            print(f"      ⚠️  同步 {os.path.basename(sf)} 失败: {e}")

# 实例2
if has_rv4 and anchor_ipv4:
    print(f"\n📋 实例2: 保留IPv4 (端口+1, Anchor: {anchor_ipv4})")
    cfg2 = copy.deepcopy(original_config); shift_ports(cfg2, 1)
    build_clean_ipv4(cfg2, anchor_ipv4)
    fp2 = f"{CONFIG_DIR}/sb-reserved-v4.json"
    with open(fp2, 'w') as f: json.dump(cfg2, f, indent=4, ensure_ascii=False)
    print(f"      ✅ {fp2}")
    generated.append(("reserved-v4", fp2, cfg2, reserved_ipv4, "保留IPv4", "ipv4", reserved_ipv4))
else:
    print("\n⏭️  实例2: 跳过")

# 实例3
print(f"\n📋 实例3: 主IPv6 (端口+2, 绑定: {main_ipv6})")
cfg3 = copy.deepcopy(original_config); shift_ports(cfg3, 2)
build_clean_ipv6(cfg3, main_ipv6)
fp3 = f"{CONFIG_DIR}/sb-ipv6.json"
with open(fp3, 'w') as f: json.dump(cfg3, f, indent=4, ensure_ascii=False)
print(f"      ✅ {fp3}")
generated.append(("ipv6", fp3, cfg3, main_public_ipv4, "主IPv6", "ipv6", main_ipv6))

# 实例4
if has_rv6 and reserved_ipv6:
    print(f"\n📋 实例4: 保留IPv6 (端口+3, 绑定: {reserved_ipv6})")
    cfg4 = copy.deepcopy(original_config); shift_ports(cfg4, 3)
    build_clean_ipv6(cfg4, reserved_ipv6)
    fp4 = f"{CONFIG_DIR}/sb-reserved-v6.json"
    with open(fp4, 'w') as f: json.dump(cfg4, f, indent=4, ensure_ascii=False)
    print(f"      ✅ {fp4}")
    generated.append(("reserved-v6", fp4, cfg4, main_public_ipv4, "保留IPv6", "ipv6", reserved_ipv6))
else:
    print("\n⏭️  实例4: 跳过")

# ═══════════════════════════════════════════════════════════
common_sni = get_common_sni(original_config)

def gen_links(cfg, ip, suffix):
    links = []
    for ib in cfg.get('inbounds', []):
        t = ib.get('type'); p = ib.get('listen_port')
        tag = ib.get('tag', '').replace('-sb', ''); lbl = f"{tag}-{hostname}-{suffix}"
        tls = ib.get('tls', {}); sni = tls.get('server_name', common_sni) or common_sni
        if t == 'vless':
            u = ib['users'][0]['uuid']; fl = ib['users'][0].get('flow', 'xtls-rprx-vision')
            r = tls.get('reality', {}); pk = r.get('private_key', ''); sid = r.get('short_id', [''])[0]
            pbk = derive_x25519_pubkey(pk) if pk else ''
            links.append(('VLESS Reality', f"vless://{u}@{ip}:{p}?encryption=none&flow={fl}&security=reality&sni={sni}&fp=chrome&pbk={pbk}&sid={sid}&type=tcp&headerType=none#{lbl}"))
        elif t == 'vmess':
            u = ib['users'][0]['uuid']; tp = ib.get('transport', {}); path = tp.get('path', ''); tls_on = tls.get('enabled', False)
            obj = {"v":"2","ps":f"vm-ws-{hostname}-{suffix}","add":ip,"port":str(p),"id":u,"aid":"0","scy":"auto","net":"ws","type":"none","host":sni,"path":path,"tls":"tls" if tls_on else "","sni":sni if tls_on else "","alpn":"","fp":"","insecure":"0"}
            links.append(('VMess WS', f"vmess://{base64.b64encode(json.dumps(obj, separators=(",",": "), ensure_ascii=False).encode()).decode()}"))
        elif t == 'hysteria2':
            links.append(('Hysteria2', f"hysteria2://{ib['users'][0]['password']}@{ip}:{p}?sni={sni}&alpn=h3&insecure=1&allowInsecure=1#{lbl}"))
        elif t == 'tuic':
            u = ib['users'][0]['uuid']; pw = ib['users'][0]['password']
            links.append(('TUIC v5', f"tuic://{quote(f'{u}:{pw}', safe='')}@{ip}:{p}?sni={sni}&alpn=h3&insecure=1&allowInsecure=1&congestion_control=bbr#{lbl}"))
        elif t == 'anytls':
            links.append(('AnyTLS', f"anytls://{ib['users'][0]['password']}@{ip}:{p}?security=tls&sni={sni}&insecure=1&allowInsecure=1&type=tcp#{lbl}"))
    return links

sections = []
for iid, ifile, icfg, cip, ilabel, etype, eip in generated:
    ll = gen_links(icfg, cip, ilabel)
    info = f"入口IPv4: {main_public_ipv4} → 出口IPv6: {eip}" if etype == "ipv6" else f"出口IPv4: {eip}"
    sections.append((f"实例-{ilabel}", info, ll))

for sn, si, sl in sections:
    print(f"\n{'='*60}\n  📡 {sn}\n  {si}\n{'='*60}")
    for n, l in sl: print(f"\n  📌 {n}:\n  {l}")

lf = f"{CONFIG_DIR}/all-links.txt"
with open(lf, 'w') as f:
    f.write(f"# DO四出口 严格隔离 | {hostname}\n# IPv4: {main_public_ipv4} / {reserved_ipv4}\n# IPv6: {main_ipv6} / {reserved_ipv6}\n\n")
    for sn, si, sl in sections:
        f.write(f"{'#'*60}\n# {sn}\n# {si}\n{'#'*60}\n\n")
        for n, l in sl: f.write(f"# {n}\n{l}\n\n")
print(f"\n💾 {lf}")

for i, (sn, si, sl) in enumerate(sections, 1):
    with open(f"{CONFIG_DIR}/links-instance{i}.txt", 'w') as f:
        f.write(f"# {sn}\n# {si}\n\n")
        for n, l in sl: f.write(f"# {n}\n{l}\n\n")

with open(f"{CONFIG_DIR}/.generated_instances", 'w') as f:
    for iid, ifile, _, _, ilabel, _, _ in generated:
        if iid != "main-v4": f.write(f"{iid}|{ifile}|{ilabel}\n")

# 验证 sb.sh 兼容性：检查关键 jq 路径
print("\n📋 sb.sh 兼容性检查:")
try:
    with open(f"{CONFIG_DIR}/sb.json", 'r') as f: check = json.load(f)
    # 甬哥脚本读取的关键路径
    tests = [
        (".inbounds[0].users[0].uuid", check.get('inbounds', [{}])[0].get('users', [{}])[0].get('uuid')),
        (".inbounds[0].listen_port", check.get('inbounds', [{}])[0].get('listen_port')),
        (".inbounds[1].listen_port", check.get('inbounds', [{},{}])[1].get('listen_port')),
        (".inbounds[1].tls.enabled", check.get('inbounds', [{},{}])[1].get('tls', {}).get('enabled')),
        (".inbounds[2].listen_port", check.get('inbounds', [{},{},{}])[2].get('listen_port')),
        (".inbounds[3].listen_port", check.get('inbounds', [{},{},{},{}])[3].get('listen_port')),
        (".outbounds[0].type", check.get('outbounds', [{}])[0].get('type')),
        (".outbounds[1].type", check.get('outbounds', [{},{}])[1].get('type')),
        (".route.rules count", len(check.get('route', {}).get('rules', []))),
    ]
    all_ok = True
    for path, val in tests:
        status = "✅" if val is not None else "❌"
        if val is None: all_ok = False
        print(f"   {status} {path} = {val}")
    if all_ok:
        print("   ✅ 全部路径有效，sb.sh 兼容")
    else:
        print("   ⚠️  部分路径缺失，请检查")
except Exception as e:
    print(f"   ❌ 检查失败: {e}")
PYEOF

[ $? -ne 0 ] && echo "❌ 生成失败" && exit 1

# ── systemd ──────────────────────────────────────────────────
echo "" && echo "⚙️  systemd 服务..."
SVC_SRC="/etc/systemd/system/sing-box.service"
[ ! -f "$SVC_SRC" ] && echo "❌ 找不到 $SVC_SRC" && exit 1
INST_INFO="/etc/s-box/.generated_instances"
if [ -f "$INST_INFO" ]; then
    while IFS='|' read -r ID FILE LABEL; do
        SVC="sing-box-${ID}"
        sed "s|sb\.json|$(basename $FILE)|g" "$SVC_SRC" > "/etc/systemd/system/${SVC}.service"
        sed -i "s/Description=.*/Description=sing-box ${LABEL}/" "/etc/systemd/system/${SVC}.service"
        echo "   ├─ ✅ ${SVC}.service ($LABEL)"
    done < "$INST_INFO"
fi
echo "   └─ sing-box.service (主IPv4 sb.json)"

echo "" && echo "🔍 验证配置..."
ALL_OK=true
if $SINGBOX_BIN check -c /etc/s-box/sb.json 2>/dev/null; then echo "   ├─ ✅ 主IPv4 (sb.json)"
else echo "   ├─ ❌ 主IPv4 (sb.json)"; $SINGBOX_BIN check -c /etc/s-box/sb.json 2>&1 | head -5 | sed 's/^/   │  /'; ALL_OK=false; fi
if [ -f "$INST_INFO" ]; then
    while IFS='|' read -r ID FILE LABEL; do
        if $SINGBOX_BIN check -c "$FILE" 2>/dev/null; then echo "   ├─ ✅ $LABEL ($(basename $FILE))"
        else echo "   ├─ ❌ $LABEL ($(basename $FILE))"; $SINGBOX_BIN check -c "$FILE" 2>&1 | head -5 | sed 's/^/   │  /'; ALL_OK=false; fi
    done < "$INST_INFO"
fi

echo "" && echo "🚀 启动全部服务..."
systemctl daemon-reload
systemctl enable sing-box >/dev/null 2>&1; systemctl restart sing-box 2>/dev/null; sleep 2
systemctl is-active --quiet sing-box && echo "   ├─ ✅ sing-box (主IPv4) - 运行中" || { echo "   ├─ ❌ sing-box (主IPv4) - 失败"; journalctl -u sing-box --no-pager -n 5 2>/dev/null | sed 's/^/   │  /'; }
if [ -f "$INST_INFO" ]; then
    while IFS='|' read -r ID FILE LABEL; do
        SVC="sing-box-${ID}"; systemctl enable "$SVC" >/dev/null 2>&1; systemctl restart "$SVC" 2>/dev/null; sleep 2
        systemctl is-active --quiet "$SVC" && echo "   ├─ ✅ $SVC ($LABEL) - 运行中" || { echo "   ├─ ❌ $SVC ($LABEL) - 失败"; journalctl -u "$SVC" --no-pager -n 5 2>/dev/null | sed 's/^/   │  /'; }
    done < "$INST_INFO"
fi

echo "" && echo "🔍 出口验证..."
SV4=$(curl -4 -sf --connect-timeout 5 --max-time 10 https://api.ipify.org 2>/dev/null || echo "N/A")
SV6=$(curl -6 -sf --connect-timeout 5 --max-time 10 https://api6.ipify.org 2>/dev/null || echo "N/A")
printf "   IPv4: %-40s (期望: %s)\n" "$SV4" "$MAIN_PUBLIC_IPV4"
printf "   IPv6: %-40s (期望: %s)\n" "$SV6" "$MAIN_IPV6"

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║          🎉 四出口严格协议隔离 — 配置完成                      ║"
echo "╠════════════════════════════════════════════════════════════════╣"
printf "║  实例1: 主IPv4     | 出口 %-35s  ║\n" "$MAIN_PUBLIC_IPV4"
echo "║         IPv4-only | DNS仅A | reject IPv6 | 兼容sb.sh        ║"
[ "$HAS_RV4" = true ] && { printf "║  实例2: 保留IPv4   | 出口 %-35s  ║\n" "$RESERVED_IPV4_LINK"; echo "║         IPv4-only | DNS仅A | reject IPv6                    ║"; }
printf "║  实例3: 主IPv6     | 出口 %-35s  ║\n" "$MAIN_IPV6"
echo "║         IPv6-only | DNS仅AAAA | reject IPv4                 ║"
[ "$HAS_RV6" = true ] && { printf "║  实例4: 保留IPv6   | 出口 %-35s  ║\n" "$RESERVED_IPV6"; echo "║         IPv6-only | DNS仅AAAA | reject IPv4                 ║"; }
echo "╠════════════════════════════════════════════════════════════════╣"
echo "║  📁 /etc/s-box/sb.json               (实例1) ⚠️已修改        ║"
echo "║  📁 /etc/s-box/sb.json.original       (原始备份)              ║"
[ "$HAS_RV4" = true ] && echo "║  📁 /etc/s-box/sb-reserved-v4.json   (实例2)                 ║"
echo "║  📁 /etc/s-box/sb-ipv6.json          (实例3)                 ║"
[ "$HAS_RV6" = true ] && echo "║  📁 /etc/s-box/sb-reserved-v6.json   (实例4)                 ║"
echo "║  🔗 /etc/s-box/all-links.txt          (全部链接)             ║"
echo "╠════════════════════════════════════════════════════════════════╣"
echo "║  恢复: cp /etc/s-box/sb.json.original /etc/s-box/sb.json     ║"
echo "║        systemctl restart sing-box                            ║"
echo "║  管理: sb (甬哥脚本正常使用)                                  ║"
echo "╚════════════════════════════════════════════════════════════════╝"
