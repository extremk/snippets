#!/bin/bash
# ====================================================
# DigitalOcean 双开保留 IP 一键配置脚本 (适配 sing-box-yg / Ubuntu 20.04-24.04)
# 兼容 sing-box 1.10.x / 1.11.x / 1.12.x / 1.13.x / 1.14.x / sb.sh 管理脚本
# 作用: 自动读取 DO Anchor IP，端口自动+1(防越界/冲突)，绑定出站网卡，严格IPv4隔离，生成订阅链接
# ====================================================

set -euo pipefail

# 1. 检查是否使用 root 运行
if [ "$EUID" -ne 0 ]; then
  echo "❌ 请使用 root 权限运行此脚本 (请加 sudo)"
  exit 1
fi

echo "============================================="
echo "🚀 开始配置 DigitalOcean 保留 IP 双开环境..."
echo "============================================="

# 2. 检查依赖与 sing-box 内核
for cmd in curl python3; do
    command -v "$cmd" &>/dev/null || { apt-get update -qq && apt-get install -y -qq "$cmd" 2>/dev/null || { echo "❌ 无法安装 $cmd"; exit 1; }; }
done
python3 -c "from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey" 2>/dev/null || {
    apt-get install -y -qq python3-cryptography 2>/dev/null || pip3 install cryptography -q 2>/dev/null || true
}

if [ -x /etc/s-box/sing-box ]; then SINGBOX_BIN="/etc/s-box/sing-box"
elif command -v sing-box &>/dev/null; then SINGBOX_BIN=$(command -v sing-box)
else echo "❌ 找不到 sing-box 可执行文件"; exit 1; fi

SB_VERSION=$($SINGBOX_BIN version 2>/dev/null | awk '/^sing-box version/{print $NF; exit}' || echo "0.0.0")
[ -z "$SB_VERSION" ] && SB_VERSION=$($SINGBOX_BIN version 2>/dev/null | awk '/version/{print $NF; exit}' || echo "0.0.0")
SB_MM=$(echo "$SB_VERSION" | cut -d'.' -f1,2 || echo "0.0")
echo "📌 sing-box: $SINGBOX_BIN (v$SB_VERSION)"

# 先停止旧的保留 IP 实例，避免端口占用干扰扫描
systemctl stop sing-box-reserved 2>/dev/null || true
pkill -9 -f "/etc/s-box/sb-reserved.json" 2>/dev/null || true
sleep 1

IFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
[ -z "$IFACE" ] && IFACE=$(ip -6 route show default 2>/dev/null | awk '/default/ {print $5; exit}')
[ -z "$IFACE" ] && IFACE="eth0"
HOST_USED_PORTS=$(ss -Htuln 2>/dev/null | awk '{print $5}' | sed -n 's/.*:\([0-9]\+\)$/\1/p' | sort -nu | paste -sd',' - || echo "")

# 3. 获取 Anchor IP（出站绑定用）和 Reserved IP（订阅链接用）
echo "🔍 正在向 DigitalOcean 元数据接口请求 IP 信息..."

MAIN_PUBLIC_IPV4=$(curl -sf http://169.254.169.254/metadata/v1/interfaces/public/0/ipv4/address 2>/dev/null || echo "")
ANCHOR_IP=$(curl -sf http://169.254.169.254/metadata/v1/interfaces/public/0/anchor_ipv4/address 2>/dev/null || echo "")
RESERVED_IP=$(curl -sf http://169.254.169.254/metadata/v1/reserved_ip/ipv4/ip_address 2>/dev/null || echo "")
HOSTNAME=$(curl -sf http://169.254.169.254/metadata/v1/hostname 2>/dev/null | cut -d'.' -f1 | tr '[:lower:]' '[:upper:]' || echo "NODE")

if [ -z "$ANCHOR_IP" ]; then
    echo "❌ 错误：无法获取 Anchor IP。请确认本机是 DigitalOcean 且已绑定 Reserved IP！"
    exit 1
fi

if [ -z "$RESERVED_IP" ]; then
    RESERVED_IP="$MAIN_PUBLIC_IPV4"
    echo "⚠️  未检测到 Reserved IP，回退使用主公网 IP: $RESERVED_IP"
else
    echo "✅ Reserved IP (订阅用): $RESERVED_IP"
fi

echo "✅ Anchor IP   (出站绑定): $ANCHOR_IP (网卡: $IFACE)"
echo "✅ 节点标签后缀: $HOSTNAME"

# 4. 检查原配置文件是否存在
SOURCE_FILE="/etc/s-box/sb.json"
TARGET_FILE="/etc/s-box/sb-reserved.json"
LINKS_FILE="/etc/s-box/reserved-links.txt"

if [ ! -f "$SOURCE_FILE" ]; then
    echo "❌ 错误：找不到原配置文件 $SOURCE_FILE，请先使用甬哥脚本完成基础部署。"
    exit 1
fi

# 5. 生成 sb-reserved.json 并生成订阅链接
echo ""
echo "⚙️  正在生成端口+1并绑定 $ANCHOR_IP 的专属配置文件..."

python3 - "$SOURCE_FILE" "$TARGET_FILE" "$ANCHOR_IP" "$RESERVED_IP" "$HOSTNAME" "$LINKS_FILE" "$SB_MM" "$IFACE" "$HOST_USED_PORTS" <<'PYEOF'
import json
import sys
import os
import base64
from urllib.parse import quote

source_file     = sys.argv[1]
target_file     = sys.argv[2]
anchor_ip       = sys.argv[3]
public_ip       = sys.argv[4]
hostname        = sys.argv[5]
links_file      = sys.argv[6]
sb_mm           = sys.argv[7]
iface_name      = sys.argv[8]
host_used_ports = sys.argv[9]

try:
    sv = sb_mm.split('.')
    sb_major, sb_minor = int(sv[0]), int(sv[1])
except Exception:
    sb_major, sb_minor = 99, 99

use_new_dns   = (sb_major > 1) or (sb_major == 1 and sb_minor >= 12)
use_new_route = (sb_major > 1) or (sb_major == 1 and sb_minor >= 11)

try:
    with open(source_file, 'r', encoding='utf-8') as f:
        config = json.load(f)
except Exception as e:
    print(f'❌ 解析 JSON 失败: {e}')
    sys.exit(1)

# 收集已占用端口（主实例所有入站端口 + 宿主机正在监听的其他端口）
used_ports = set()
for ib in config.get('inbounds', []):
    p = ib.get('listen_port')
    if isinstance(p, int):
        used_ports.add(p)
for p_str in host_used_ports.split(','):
    if p_str.strip().isdigit():
        used_ports.add(int(p_str.strip()))

# 端口 + 1（自动处理 >65535 越界与端口冲突）
if 'inbounds' in config:
    for inbound in config['inbounds']:
        inbound['listen'] = '0.0.0.0'
        if 'listen_port' in inbound and isinstance(inbound['listen_port'], int):
            old_port = inbound['listen_port']
            preferred = old_port + 1
            if 1 <= preferred <= 65535 and preferred not in used_ports:
                new_port = preferred
                print(f"✅ 端口自动修改成功: {old_port} -> {new_port}")
            else:
                cand = (old_port - 100 + 1) if preferred > 65535 else preferred
                if cand < 10000 or cand > 65535:
                    cand = 65434
                found = None
                for _ in range(55536):
                    if 10000 <= cand <= 65535 and cand not in used_ports:
                        found = cand
                        break
                    cand -= 1
                    if cand < 10000:
                        cand = 65535
                if found is None:
                    print(f"❌ 无可用端口可分配 (原端口: {old_port})")
                    sys.exit(1)
                new_port = found
                reason = "超出65535" if preferred > 65535 else "端口冲突"
                print(f"✅ 端口自动调整成功: {old_port} -> {new_port} (原目标 {preferred} {reason})")
            inbound['listen_port'] = new_port
            used_ports.add(new_port)

# DNS 严格 IPv4-only + 绑定 direct-dns 防止从主 IP 泄漏 DNS 请求
if use_new_dns:
    config['dns'] = {
        "servers": [
            {"tag": "ipv4-dns-cf", "type": "tls", "server": "1.1.1.1", "server_port": 853, "detour": "direct-dns"},
            {"tag": "ipv4-dns-google", "type": "tls", "server": "8.8.8.8", "server_port": 853, "detour": "direct-dns"}
        ],
        "final": "ipv4-dns-cf",
        "strategy": "ipv4_only",
        "disable_cache": False,
        "independent_cache": True
    }
else:
    config['dns'] = {
        "servers": [
            {"tag": "ipv4-dns-cf", "address": "tls://1.1.1.1", "address_strategy": "ipv4_only", "strategy": "ipv4_only", "detour": "direct-dns"}
        ],
        "final": "ipv4-dns-cf",
        "strategy": "ipv4_only",
        "disable_cache": False,
        "independent_cache": True
    }

# 出站严格绑定 Anchor IP
direct_ob = {
    "type": "direct",
    "tag": "direct",
    "bind_interface": iface_name,
    "inet4_bind_address": anchor_ip,
    "bind_address_no_port": True,
    "tcp_multi_path": False,
    "tcp_fast_open": False,
    "udp_fragment": True
}
direct_dns_ob = {
    "type": "direct",
    "tag": "direct-dns",
    "bind_interface": iface_name,
    "inet4_bind_address": anchor_ip,
    "bind_address_no_port": True,
    "tcp_multi_path": False,
    "tcp_fast_open": False,
    "udp_fragment": True
}
if use_new_dns:
    direct_ob["domain_resolver"] = "ipv4-dns-cf"

if use_new_route:
    route = {
        "rules": [
            {"action": "sniff", "timeout": "1s"},
            {"protocol": "dns", "action": "hijack-dns"},
            {"ip_version": 6, "action": "reject", "method": "default"},
            {"ip_cidr": ["::/0"], "action": "reject", "method": "default"}
        ],
        "final": "direct",
        "auto_detect_interface": False
    }
    if use_new_dns:
        route["default_domain_resolver"] = {"server": "ipv4-dns-cf"}
    config['route'] = route
    config['outbounds'] = [direct_ob, direct_dns_ob]
else:
    config['route'] = {
        "rules": [
            {"protocol": "dns", "outbound": "dns-out"},
            {"ip_cidr": ["::/0"], "outbound": "block"}
        ],
        "final": "direct",
        "auto_detect_interface": False
    }
    config['outbounds'] = [
        direct_ob,
        direct_dns_ob,
        {"type": "dns", "tag": "dns-out"},
        {"type": "block", "tag": "block"}
    ]

# 移除 sb11.json 的 warp endpoints，防止从默认路由泄漏
config.pop('endpoints', None)

with open(target_file, 'w', encoding='utf-8') as f:
    json.dump(config, f, indent=4, ensure_ascii=False)
print(f"✅ 出站网卡绑定成功: 锁定至 {anchor_ip} (IPv4-only 隔离)")

# ── 从 X25519 私钥推导公钥（用于 VLESS Reality pbk 参数）──────────────
def derive_x25519_pubkey(private_key_b64url):
    try:
        from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
        from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
        pad = private_key_b64url + '=' * (-len(private_key_b64url) % 4)
        raw = base64.urlsafe_b64decode(pad)
        priv = X25519PrivateKey.from_private_bytes(raw)
        pub_raw = priv.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
        return base64.urlsafe_b64encode(pub_raw).rstrip(b'=').decode()
    except Exception:
        pub_file = "/etc/s-box/public.key"
        if os.path.exists(pub_file):
            try:
                with open(pub_file, 'r', encoding='utf-8') as pf:
                    return pf.read().strip()
            except Exception:
                pass
        print("⚠️  公钥推导失败且未找到 /etc/s-box/public.key，pbk 将留空，请手动填写。")
        return ""

# ── 查找通用 SNI（取 vmess 的 server_name，用于其他协议兜底）─────────────
common_sni = "www.bing.com"
for inbound in config.get('inbounds', []):
    if inbound.get('type') == 'vmess':
        sni = inbound.get('tls', {}).get('server_name', '')
        if sni:
            common_sni = sni
            break

links = []

for inbound in config.get('inbounds', []):
    itype = inbound.get('type')
    port  = inbound.get('listen_port')
    tag   = inbound.get('tag', '').replace('-sb', '')
    label = f"{tag}-{hostname}-备用IP"
    tls   = inbound.get('tls', {})
    sni   = tls.get('server_name', common_sni) or common_sni

    if itype == 'vless':
        uuid     = inbound['users'][0]['uuid']
        flow     = inbound['users'][0].get('flow', 'xtls-rprx-vision')
        reality  = tls.get('reality', {})
        priv_key = reality.get('private_key', '')
        short_id = reality.get('short_id', [''])[0]
        pbk      = derive_x25519_pubkey(priv_key) if priv_key else ''
        link = (
            f"vless://{uuid}@{public_ip}:{port}"
            f"?encryption=none&flow={flow}&security=reality"
            f"&sni={sni}&fp=chrome&pbk={pbk}&sid={short_id}"
            f"&type=tcp&headerType=none#{label}"
        )
        links.append(('VLESS Reality', link))

    elif itype == 'vmess':
        uuid      = inbound['users'][0]['uuid']
        transport = inbound.get('transport', {})
        path      = transport.get('path', '')
        tls_on    = tls.get('enabled', False)
        vmess_obj = {
            "v":        "2",
            "ps":       f"vm-ws-{hostname}-备用IP",
            "add":      public_ip,
            "port":     str(port),
            "id":       uuid,
            "aid":      "0",
            "scy":      "auto",
            "net":      "ws",
            "type":     "none",
            "host":     sni,
            "path":     path,
            "tls":      "tls" if tls_on else "",
            "sni":      sni if tls_on else "",
            "alpn":     "",
            "fp":       "",
            "insecure": "0"
        }
        encoded = base64.b64encode(
            json.dumps(vmess_obj, separators=(',', ': '), ensure_ascii=False).encode()
        ).decode()
        links.append(('VMess WS', f"vmess://{encoded}"))

    elif itype == 'hysteria2':
        password = inbound['users'][0]['password']
        link = (
            f"hysteria2://{password}@{public_ip}:{port}"
            f"?sni={sni}&alpn=h3&insecure=1&allowInsecure=1#{label}"
        )
        links.append(('Hysteria2', link))

    elif itype == 'tuic':
        uuid     = inbound['users'][0]['uuid']
        password = inbound['users'][0]['password']
        auth     = quote(f"{uuid}:{password}", safe=':')
        link = (
            f"tuic://{auth}@{public_ip}:{port}"
            f"?sni={sni}&alpn=h3&insecure=1&allowInsecure=1&allow_insecure=1&udp_relay_mode=native&congestion_control=bbr#{label}"
        )
        links.append(('TUIC v5', link))

    elif itype == 'anytls':
        password = inbound['users'][0]['password']
        link = (
            f"anytls://{password}@{public_ip}:{port}"
            f"?security=tls&sni={sni}&insecure=1&allowInsecure=1&type=tcp#{label}"
        )
        links.append(('AnyTLS', link))

print(f"\n{'='*60}")
print(f"  📡 Reserved IP: {public_ip}  |  节点标签: {hostname}")
print(f"{'='*60}")

all_links_text = []
for name, link in links:
    print(f"\n📌 {name}:")
    print(link)
    all_links_text.append(f"# {name}\n{link}")

print(f"\n{'─'*60}")

with open(links_file, 'w', encoding='utf-8') as f:
    f.write("# 保留 IP 节点订阅链接\n")
    f.write(f"# Reserved IP: {public_ip}\n\n")
    f.write("\n\n".join(all_links_text))
    f.write("\n")

print(f"💾 订阅链接已保存至: {links_file}")
PYEOF

echo "✅ 新配置文件已生成至: $TARGET_FILE"

# 6. 验证生成的配置
echo ""
echo "🔍 验证保留 IP 配置..."
if ! $SINGBOX_BIN check -c "$TARGET_FILE" 2>/dev/null; then
    echo "❌ 配置验证失败:"
    $SINGBOX_BIN check -c "$TARGET_FILE" 2>&1 | head -10 | sed 's/^/   /'
    exit 1
fi
echo "   └─ ✅ 配置校验通过 ($TARGET_FILE)"

# 7. 配置 systemd 服务 (sing-box-reserved)
echo ""
echo "⚙️  配置双开系统服务..."
SERVICE_SOURCE="/etc/systemd/system/sing-box.service"
SERVICE_TARGET="/etc/systemd/system/sing-box-reserved.service"

if [ ! -f "$SERVICE_SOURCE" ]; then
    echo "❌ 错误：找不到源服务文件 $SERVICE_SOURCE"
    exit 1
fi

sed 's/sb\.json/sb-reserved.json/g' "$SERVICE_SOURCE" > "$SERVICE_TARGET"
sed -i 's|^After=.*|After=network-online.target\nWants=network-online.target|' "$SERVICE_TARGET"

# 8. 重载并启动服务
systemctl daemon-reload
systemctl enable sing-box-reserved >/dev/null 2>&1
systemctl restart sing-box-reserved || true
sleep 2

if ! systemctl is-active --quiet sing-box-reserved; then
    echo "❌ sing-box-reserved 服务启动失败，最近日志："
    journalctl -u sing-box-reserved --no-pager -n 10 2>/dev/null | sed 's/^/   /'
    exit 1
fi
echo "   └─ ✅ sing-box-reserved.service 运行中"

# 9. 出口 IP 核验
echo ""
echo "🔍 出口验证..."
RV4_CHK=$(curl -4 -sf --interface "$ANCHOR_IP" --connect-timeout 5 --max-time 10 https://api.ipify.org 2>/dev/null || echo "N/A")
printf "   保留IPv4: %-30s (期望: %s)\n" "$RV4_CHK" "$RESERVED_IP"

echo ""
echo "============================================="
echo "🎉 全部完成！保留 IP 双开实例已启动！"
echo "---------------------------------------------"
echo "📡 Reserved IP : $RESERVED_IP"
echo "🔗 订阅链接文件: $LINKS_FILE"
echo "👉 副节点端口已自动 +1（超限/冲突自动调整）"
echo "👉 主节点重置后，重新运行此脚本一键恢复"
echo "============================================="
