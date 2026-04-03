#!/bin/bash
# ====================================================
# DigitalOcean 四出口一键配置脚本 (适配 sing-box-yg)
# 兼容 sing-box 1.10.x / 1.11.x / 1.12.x / 1.13.x
#
# 出口架构:
#   实例1: 主IPv4      (主端口)   - sb.json (不修改)
#   实例2: 保留IPv4    (端口+1)   - sb-reserved-v4.json
#   实例3: 主IPv6      (端口+2)   - sb-ipv6.json
#   实例4: 保留IPv6    (端口+3)   - sb-reserved-v6.json
# ====================================================

set -euo pipefail

[ "$EUID" -ne 0 ] && echo "❌ 请使用 root 运行" && exit 1

echo "============================================="
echo "🚀 DigitalOcean 四出口配置 (双IPv4 + 双IPv6)"
echo "============================================="

# ── 依赖 ─────────────────────────────────────────────────────
for cmd in curl jq python3; do
    command -v "$cmd" &>/dev/null || {
        apt-get update -qq && apt-get install -y -qq "$cmd" 2>/dev/null || { echo "❌ 无法安装 $cmd"; exit 1; }
    }
done
python3 -c "from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey" 2>/dev/null || {
    pip3 install cryptography -q 2>/dev/null || apt-get install -y -qq python3-cryptography 2>/dev/null || true
}

# ── sing-box ─────────────────────────────────────────────────
if [ -x /etc/s-box/sing-box ]; then
    SINGBOX_BIN="/etc/s-box/sing-box"
elif command -v sing-box &>/dev/null; then
    SINGBOX_BIN=$(command -v sing-box)
else
    echo "❌ 找不到 sing-box"; exit 1
fi

SB_VERSION=$($SINGBOX_BIN version 2>/dev/null | awk '/version/{print $NF}' || echo "0.0.0")
SB_MM=$($SINGBOX_BIN version 2>/dev/null | awk '/version/{print $NF}' | cut -d'.' -f1,2 || echo "0.0")
echo "📌 sing-box: $SINGBOX_BIN (v$SB_VERSION)"

# ── 停止旧的副实例服务（防止端口冲突）─────────────────────────
echo ""
echo "🔄 停止旧的副实例服务..."
for svc in sing-box-reserved-v4 sing-box-ipv6 sing-box-reserved-v6; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        systemctl stop "$svc" 2>/dev/null
        echo "   ├─ 已停止 $svc"
    fi
done
sleep 1

# ── DO 元数据 ────────────────────────────────────────────────
echo ""
echo "🔍 查询 DigitalOcean 元数据..."
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

# ── 验证 ─────────────────────────────────────────────────────
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
echo "" && echo "✅ 原始配置: $SOURCE_FILE"

# ── IPv6 路由 ────────────────────────────────────────────────
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

# ── Python 生成 ──────────────────────────────────────────────
echo "" && echo "⚙️  生成配置..."

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

CONFIG_DIR = "/etc/s-box"

try:
    sv = sb_mm.split('.')
    sb_major, sb_minor = int(sv[0]), int(sv[1])
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
        pad = pk + '=' * (-len(pk) % 4)
        raw = base64.urlsafe_b64decode(pad)
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
            old = ib['listen_port']
            ib['listen_port'] = old + offset
            print(f"      端口: {old} -> {old + offset}")

def force_ipv4_listen(cfg):
    for ib in cfg.get('inbounds', []):
        ib['listen'] = '0.0.0.0'

def build_ipv6_dns():
    """
    严格 IPv6-only DNS
    全局 strategy: ipv6_only → 所有解析仅返回 AAAA 记录
    DNS 服务器直接用 IPv6 地址，不需要域名解析
    """
    if use_new_dns:
        return {
            "servers": [
                {"tag": "ipv6-dns-cf", "type": "tls", "server": "2606:4700:4700::1111", "server_port": 853},
                {"tag": "ipv6-dns-google", "type": "tls", "server": "2001:4860:4860::8888", "server_port": 853}
            ],
            "final": "ipv6-dns-cf",
            "strategy": "ipv6_only",
            "disable_cache": False,
            "independent_cache": True
        }
    else:
        return {
            "servers": [
                {"tag": "ipv6-dns-cf", "address": "tls://[2606:4700:4700::1111]", "address_strategy": "ipv6_only", "strategy": "ipv6_only", "detour": "direct"},
                {"tag": "ipv6-dns-google", "address": "tls://[2001:4860:4860::8888]", "address_strategy": "ipv6_only", "strategy": "ipv6_only", "detour": "direct"}
            ],
            "final": "ipv6-dns-cf",
            "strategy": "ipv6_only",
            "disable_cache": False,
            "independent_cache": True
        }

def build_ipv6_route():
    """
    严格 IPv6 路由 — IPv4 全拦截
    
    关键: final 必须指向一个已存在的 outbound tag
    不能用 "reject" 作为 final（那不是 outbound tag）
    
    设计:
    - 规则1: sniff 提取域名
    - 规则2: hijack-dns 到本地 ipv6_only 解析器
    - 规则3: reject 所有 ip_version:4 (TCP RST / ICMP unreachable)
    - 规则4: reject 0.0.0.0/0 (双重保险)
    - 无需最后 route->direct 规则，由 final 兜底
    
    final: "direct" — 所有通过上面 reject 规则的流量（即 IPv6）
    走 direct 出站，direct 已绑定指定 IPv6 地址
    """
    if use_new_route:
        route = {
            "rules": [
                {"action": "sniff", "timeout": "1s"},
                {"protocol": "dns", "action": "hijack-dns"},
                {"ip_version": 4, "action": "reject", "method": "default"},
                {"ip_cidr": ["0.0.0.0/0"], "action": "reject", "method": "default"}
            ],
            "final": "direct",
            "auto_detect_interface": False
        }
        if use_new_dns:
            route["default_domain_resolver"] = {"server": "ipv6-dns-cf"}
        return route
    else:
        return {
            "rules": [
                {"protocol": ["quic", "stun"], "outbound": "block-out"},
                {"outbound": "direct", "network": "udp,tcp"}
            ],
            "auto_detect_interface": False
        }

def build_ipv6_outbounds(bind_v6):
    """
    严格 IPv6 出站
    
    只有一个 direct 出站，强制绑定到指定 IPv6 地址
    route.final 指向这个 direct
    IPv4 流量在路由规则中被 reject，永远到不了这里
    """
    direct_ob = {
        "type": "direct",
        "tag": "direct",
        "bind_interface": "eth0",
        "inet6_bind_address": bind_v6,
        "bind_address_no_port": True,
        "tcp_multi_path": False,
        "tcp_fast_open": False,
        "udp_fragment": True
    }
    if use_new_dns:
        direct_ob["domain_resolver"] = "ipv6-dns-cf"
    
    obs = [direct_ob]
    if not use_new_route:
        obs.append({"type": "block", "tag": "block-out"})
    return obs

def apply_ipv6(cfg, bind_v6):
    force_ipv4_listen(cfg)
    cfg['dns'] = build_ipv6_dns()
    cfg['route'] = build_ipv6_route()
    cfg['outbounds'] = build_ipv6_outbounds(bind_v6)
    cfg.pop('endpoints', None)
    return cfg

# ═══════════════════════════════════════════════════════════
generated = []

# 实例2
if has_rv4 and anchor_ipv4:
    print(f"\n📋 实例2: 保留IPv4 (端口+1, Anchor: {anchor_ipv4})")
    c = copy.deepcopy(original_config)
    shift_ports(c, 1)
    bound = False
    for ob in c.get('outbounds', []):
        if ob.get('tag') == 'direct' and ob.get('type') == 'direct':
            ob['inet4_bind_address'] = anchor_ipv4
            ob['udp_fragment'] = True
            ob['bind_address_no_port'] = True
            bound = True; break
    if not bound:
        c.setdefault('outbounds', []).insert(0, {
            "type": "direct", "tag": "direct",
            "inet4_bind_address": anchor_ipv4, "udp_fragment": True, "bind_address_no_port": True
        })
    print(f"      出站绑定: {anchor_ipv4}")
    fp = f"{CONFIG_DIR}/sb-reserved-v4.json"
    with open(fp, 'w') as f: json.dump(c, f, indent=4, ensure_ascii=False)
    print(f"      ✅ {fp}")
    generated.append(("reserved-v4", fp, c, reserved_ipv4, "保留IPv4"))
else:
    print("\n⏭️  实例2: 跳过")

# 实例3
print(f"\n📋 实例3: 主IPv6 (端口+2, 绑定: {main_ipv6})")
c = copy.deepcopy(original_config)
shift_ports(c, 2)
apply_ipv6(c, main_ipv6)
fp = f"{CONFIG_DIR}/sb-ipv6.json"
with open(fp, 'w') as f: json.dump(c, f, indent=4, ensure_ascii=False)
print(f"      ✅ {fp}")
generated.append(("ipv6", fp, c, main_public_ipv4, "主IPv6"))

# 实例4
if has_rv6 and reserved_ipv6:
    print(f"\n📋 实例4: 保留IPv6 (端口+3, 绑定: {reserved_ipv6})")
    c = copy.deepcopy(original_config)
    shift_ports(c, 3)
    apply_ipv6(c, reserved_ipv6)
    fp = f"{CONFIG_DIR}/sb-reserved-v6.json"
    with open(fp, 'w') as f: json.dump(c, f, indent=4, ensure_ascii=False)
    print(f"      ✅ {fp}")
    generated.append(("reserved-v6", fp, c, main_public_ipv4, "保留IPv6"))
else:
    print("\n⏭️  实例4: 跳过")

# ═══════════════════════════════════════════════════════════
common_sni = get_common_sni(original_config)

def gen_links(cfg, ip, suffix):
    links = []
    for ib in cfg.get('inbounds', []):
        t = ib.get('type'); p = ib.get('listen_port')
        tag = ib.get('tag', '').replace('-sb', '')
        lbl = f"{tag}-{hostname}-{suffix}"
        tls = ib.get('tls', {}); sni = tls.get('server_name', common_sni) or common_sni
        if t == 'vless':
            u = ib['users'][0]['uuid']; fl = ib['users'][0].get('flow', 'xtls-rprx-vision')
            r = tls.get('reality', {}); pk = r.get('private_key', ''); sid = r.get('short_id', [''])[0]
            pbk = derive_x25519_pubkey(pk) if pk else ''
            links.append(('VLESS Reality', f"vless://{u}@{ip}:{p}?encryption=none&flow={fl}&security=reality&sni={sni}&fp=chrome&pbk={pbk}&sid={sid}&type=tcp&headerType=none#{lbl}"))
        elif t == 'vmess':
            u = ib['users'][0]['uuid']; tp = ib.get('transport', {}); path = tp.get('path', '')
            tls_on = tls.get('enabled', False)
            obj = {"v":"2","ps":f"vm-ws-{hostname}-{suffix}","add":ip,"port":str(p),"id":u,"aid":"0","scy":"auto","net":"ws","type":"none","host":sni,"path":path,"tls":"tls" if tls_on else "","sni":sni if tls_on else "","alpn":"","fp":"","insecure":"0"}
            links.append(('VMess WS', f"vmess://{base64.b64encode(json.dumps(obj, separators=(',',': '), ensure_ascii=False).encode()).decode()}"))
        elif t == 'hysteria2':
            links.append(('Hysteria2', f"hysteria2://{ib['users'][0]['password']}@{ip}:{p}?sni={sni}&alpn=h3&insecure=1&allowInsecure=1#{lbl}"))
        elif t == 'tuic':
            u = ib['users'][0]['uuid']; pw = ib['users'][0]['password']
            links.append(('TUIC v5', f"tuic://{quote(f'{u}:{pw}', safe='')}@{ip}:{p}?sni={sni}&alpn=h3&insecure=1&allowInsecure=1&congestion_control=bbr#{lbl}"))
        elif t == 'anytls':
            links.append(('AnyTLS', f"anytls://{ib['users'][0]['password']}@{ip}:{p}?security=tls&sni={sni}&insecure=1&allowInsecure=1&type=tcp#{lbl}"))
    return links

sections = []
sections.append(("实例1-主IPv4", f"出口: {main_public_ipv4}", gen_links(original_config, main_public_ipv4, "主IPv4")))
for iid, ifile, icfg, iip, ilabel in generated:
    ll = gen_links(icfg, iip, ilabel)
    if "ipv6" in iid:
        v6a = reserved_ipv6 if "reserved" in iid else main_ipv6
        info = f"入口: {main_public_ipv4} → 出口: {v6a}"
    else:
        info = f"出口: {iip}"
    sections.append((f"实例-{ilabel}", info, ll))

for sn, si, sl in sections:
    print(f"\n{'='*60}\n  📡 {sn} | {si}\n{'='*60}")
    for n, l in sl:
        print(f"  📌 {n}: {l[:90]}..." if len(l) > 100 else f"  📌 {n}: {l}")

lf = f"{CONFIG_DIR}/all-links.txt"
with open(lf, 'w') as f:
    f.write(f"# DO四出口 | {hostname} | IPv4:{main_public_ipv4} | IPv6:{main_ipv6}\n\n")
    for sn, si, sl in sections:
        f.write(f"{'#'*60}\n# {sn} | {si}\n{'#'*60}\n\n")
        for n, l in sl: f.write(f"# {n}\n{l}\n\n")
print(f"\n💾 {lf}")

for i, (sn, si, sl) in enumerate(sections, 1):
    with open(f"{CONFIG_DIR}/links-instance{i}.txt", 'w') as f:
        f.write(f"# {sn} | {si}\n\n")
        for n, l in sl: f.write(f"# {n}\n{l}\n\n")

with open(f"{CONFIG_DIR}/.generated_instances", 'w') as f:
    for iid, ifile, _, _, ilabel in generated:
        f.write(f"{iid}|{ifile}|{ilabel}\n")
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

# ── 验证 ─────────────────────────────────────────────────────
echo "" && echo "🔍 验证配置..."
ALL_OK=true
if [ -f "$INST_INFO" ]; then
    while IFS='|' read -r ID FILE LABEL; do
        if $SINGBOX_BIN check -c "$FILE" 2>/dev/null; then
            echo "   ├─ ✅ $LABEL ($(basename $FILE))"
        else
            echo "   ├─ ❌ $LABEL ($(basename $FILE))"
            $SINGBOX_BIN check -c "$FILE" 2>&1 | head -5 | sed 's/^/   │  /'
            ALL_OK=false
        fi
    done < "$INST_INFO"
fi

# ── 启动 ─────────────────────────────────────────────────────
echo "" && echo "🚀 启动服务..."
systemctl daemon-reload
if [ -f "$INST_INFO" ]; then
    while IFS='|' read -r ID FILE LABEL; do
        SVC="sing-box-${ID}"
        systemctl enable "$SVC" >/dev/null 2>&1
        systemctl restart "$SVC" 2>/dev/null; sleep 1
        if systemctl is-active --quiet "$SVC"; then
            echo "   ├─ ✅ $SVC ($LABEL) - 运行中"
        else
            echo "   ├─ ❌ $SVC ($LABEL) - 失败"
            journalctl -u "$SVC" --no-pager -n 5 2>/dev/null | sed 's/^/   │  /'
        fi
    done < "$INST_INFO"
fi

# ── 出口验证 ─────────────────────────────────────────────────
echo "" && echo "🔍 出口验证..."
SV4=$(curl -4 -sf --connect-timeout 5 --max-time 10 https://api.ipify.org 2>/dev/null || echo "N/A")
SV6=$(curl -6 -sf --connect-timeout 5 --max-time 10 https://api6.ipify.org 2>/dev/null || echo "N/A")
printf "   IPv4: %-40s (期望: %s)\n" "$SV4" "$MAIN_PUBLIC_IPV4"
printf "   IPv6: %-40s (期望: %s)\n" "$SV6" "$MAIN_IPV6"

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║                   🎉 四出口配置完成                           ║"
echo "╠═══════════════════════════════════════════════════════════════╣"
printf "║  实例1: 主IPv4     | %-41s║\n" "$MAIN_PUBLIC_IPV4 (原始)"
[ "$HAS_RV4" = true ] && printf "║  实例2: 保留IPv4   | %-41s║\n" "$RESERVED_IPV4_LINK (端口+1)"
printf "║  实例3: 主IPv6     | %-41s║\n" "$MAIN_IPV6 (端口+2)"
[ "$HAS_RV6" = true ] && printf "║  实例4: 保留IPv6   | %-41s║\n" "$RESERVED_IPV6 (端口+3)"
echo "╠═══════════════════════════════════════════════════════════════╣"
echo "║  📁 /etc/s-box/sb.json                       (实例1)         ║"
[ "$HAS_RV4" = true ] && echo "║  📁 /etc/s-box/sb-reserved-v4.json         (实例2)         ║"
echo "║  📁 /etc/s-box/sb-ipv6.json                  (实例3)         ║"
[ "$HAS_RV6" = true ] && echo "║  📁 /etc/s-box/sb-reserved-v6.json         (实例4)         ║"
echo "║  🔗 /etc/s-box/all-links.txt                                 ║"
echo "╠═══════════════════════════════════════════════════════════════╣"
echo "║  ⚠️  IPv6严格模式(实例3/4):                                   ║"
echo "║     • DNS: strategy:ipv6_only + default_domain_resolver      ║"
echo "║     • 路由: ip_version:4 + 0.0.0.0/0 双重 reject action     ║"
echo "║     • 出站: inet6_bind_address 绑定 + domain_resolver        ║"
echo "║     • final → direct (已绑IPv6), IPv4 在规则层被 reject      ║"
echo "║     • 纯IPv4网站不可达（预期行为）                             ║"
echo "╠═══════════════════════════════════════════════════════════════╣"
echo "║  🛠️  管理:                                                     ║"
echo "║  systemctl status sing-box                          (主IPv4) ║"
[ "$HAS_RV4" = true ] && echo "║  systemctl status sing-box-reserved-v4              (保留IPv4)║"
echo "║  systemctl status sing-box-ipv6                     (主IPv6) ║"
[ "$HAS_RV6" = true ] && echo "║  systemctl status sing-box-reserved-v6              (保留IPv6)║"
echo "║  cat /etc/s-box/all-links.txt                        (链接) ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
