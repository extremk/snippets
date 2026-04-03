#!/bin/bash
# ====================================================
# DigitalOcean 四出口一键配置脚本 (适配 Ubuntu 24.04)
# 
# 出口架构:
#   实例1: 主IPv4出口      (主端口)     - sb.json (原始，不修改)
#   实例2: 保留IPv4出口    (主端口+1)   - sb-reserved-v4.json
#   实例3: 主IPv6出口      (主端口+2)   - sb-ipv6.json
#   实例4: 保留IPv6出口    (主端口+3)   - sb-reserved-v6.json
#
# IPv6实例特性:
#   - 客户端入口: IPv4 (listen 0.0.0.0)
#   - 出口: 严格纯IPv6，绝不回退IPv4
#   - DNS: 强制 ipv6_only 策略
#   - 路由: 拦截所有IPv4流量
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

# 确保 python3 cryptography 库可用（用于推导 X25519 公钥）
python3 -c "from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey" 2>/dev/null || {
    echo "📦 安装 Python cryptography 库..."
    pip3 install cryptography -q 2>/dev/null || apt-get install -y -qq python3-cryptography 2>/dev/null || true
}

# ── 3. 从 DigitalOcean 元数据 API 获取所有 IP 信息 ─────────
echo ""
echo "🔍 正在查询 DigitalOcean 元数据接口..."

METADATA=$(curl -sf http://169.254.169.254/metadata/v1.json 2>/dev/null) || {
    echo "❌ 无法访问 DO 元数据 API，请确认本机为 DigitalOcean Droplet"
    exit 1
}

# 主 IPv4 信息
MAIN_PUBLIC_IPV4=$(echo "$METADATA" | jq -r '.interfaces.public[0].ipv4.address // empty')
MAIN_ANCHOR_IPV4=$(echo "$METADATA" | jq -r '.interfaces.public[0].anchor_ipv4.address // empty')

# 保留 IPv4 信息
RESERVED_IPV4=$(echo "$METADATA" | jq -r '.reserved_ip.ipv4.ip_address // empty')

# 主 IPv6 信息
MAIN_IPV6=$(echo "$METADATA" | jq -r '.interfaces.public[0].ipv6.address // empty')
MAIN_IPV6_GATEWAY=$(echo "$METADATA" | jq -r '.interfaces.public[0].ipv6.gateway // empty')

# 保留 IPv6 信息
RESERVED_IPV6=$(echo "$METADATA" | jq -r '.reserved_ip.ipv6.ip_address // empty')
RESERVED_IPV6_ACTIVE=$(echo "$METADATA" | jq -r '.reserved_ip.ipv6.active // empty')

# 主机名标签
HOSTNAME_LABEL=$(echo "$METADATA" | jq -r '.hostname // "unknown"' | cut -d'.' -f1 | tr '[:lower:]' '[:upper:]')

echo ""
echo "┌─────────────────────────────────────────────┐"
echo "│           IP 地址信息汇总                    │"
echo "├─────────────────────────────────────────────┤"
printf "│ 主公网IPv4      : %-25s│\n" "${MAIN_PUBLIC_IPV4:-N/A}"
printf "│ Anchor IPv4     : %-25s│\n" "${MAIN_ANCHOR_IPV4:-N/A}"
printf "│ 保留 IPv4       : %-25s│\n" "${RESERVED_IPV4:-N/A}"
printf "│ 主 IPv6         : %-25s│\n" "${MAIN_IPV6:-N/A}"
printf "│ IPv6 网关       : %-25s│\n" "${MAIN_IPV6_GATEWAY:-N/A}"
printf "│ 保留 IPv6       : %-25s│\n" "${RESERVED_IPV6:-N/A}"
printf "│ 保留IPv6已激活  : %-25s│\n" "${RESERVED_IPV6_ACTIVE:-N/A}"
printf "│ 节点标签        : %-25s│\n" "$HOSTNAME_LABEL"
echo "└─────────────────────────────────────────────┘"

# ── 4. 验证必要的 IP 地址 ────────────────────────────────────
ERRORS=()

if [ -z "$MAIN_PUBLIC_IPV4" ]; then
    ERRORS+=("主公网IPv4地址不可用")
fi

if [ -z "$MAIN_ANCHOR_IPV4" ]; then
    echo "⚠️  未检测到 Anchor IPv4，保留IPv4出口将不可用"
fi

if [ -z "$RESERVED_IPV4" ]; then
    echo "⚠️  未检测到保留IPv4，将使用主公网IPv4生成订阅链接"
    RESERVED_IPV4="$MAIN_PUBLIC_IPV4"
fi

if [ -z "$MAIN_IPV6" ]; then
    ERRORS+=("主IPv6地址不可用 - 请在DO控制面板启用IPv6")
fi

if [ -z "$RESERVED_IPV6" ] || [ "$RESERVED_IPV6_ACTIVE" != "true" ]; then
    ERRORS+=("保留IPv6地址不可用或未激活 - 请先手动激活")
fi

if [ ${#ERRORS[@]} -gt 0 ]; then
    echo ""
    echo "❌ 检测到以下致命错误:"
    for err in "${ERRORS[@]}"; do
        echo "   • $err"
    done
    exit 1
fi

# ── 5. 检查原始配置文件 ──────────────────────────────────────
SOURCE_FILE="/etc/s-box/sb.json"
if [ ! -f "$SOURCE_FILE" ]; then
    echo "❌ 找不到原配置文件 $SOURCE_FILE"
    echo "   请先使用甬哥脚本完成基础部署"
    exit 1
fi

echo ""
echo "✅ 原始配置文件已找到: $SOURCE_FILE"

# ── 6. 配置内核级 IPv6 路由 ──────────────────────────────────
echo ""
echo "⚙️  配置内核级 IPv6 路由..."

# 6a. 确保主 IPv6 路由正常
echo "   ├─ 主 IPv6 地址: $MAIN_IPV6"

# 6b. 配置保留 IPv6 地址到 lo 接口
echo "   ├─ 绑定保留 IPv6 到 lo 接口..."
ip -6 addr replace "${RESERVED_IPV6}/128" dev lo scope global 2>/dev/null || {
    echo "   │  ⚠️  绑定保留IPv6到lo失败，尝试添加..."
    ip -6 addr add "${RESERVED_IPV6}/128" dev lo scope global 2>/dev/null || true
}

# 6c. 验证保留 IPv6 可达性
if ip -6 addr show dev lo | grep -q "$RESERVED_IPV6"; then
    echo "   ├─ ✅ 保留 IPv6 已绑定到 lo 接口"
else
    echo "   ├─ ❌ 保留 IPv6 绑定失败"
    exit 1
fi

# 6d. 确保 IPv6 转发开启
sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1 || true

# 6e. 创建持久化脚本
PERSIST_SCRIPT="/etc/s-box/setup-reserved-ipv6.sh"
cat > "$PERSIST_SCRIPT" << EOFPERSIST
#!/bin/bash
# 持久化保留 IPv6 路由配置
RESERVED_IPV6="${RESERVED_IPV6}"
ip -6 addr replace "\${RESERVED_IPV6}/128" dev lo scope global 2>/dev/null || true
echo "[\$(date)] 保留IPv6路由已恢复: \${RESERVED_IPV6}" >> /var/log/reserved-ipv6.log
EOFPERSIST
chmod +x "$PERSIST_SCRIPT"

# 注册 systemd 开机服务
cat > /etc/systemd/system/setup-reserved-ipv6.service << EOFSVC
[Unit]
Description=Setup DigitalOcean Reserved IPv6 Route
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
systemctl enable setup-reserved-ipv6.service >/dev/null 2>&1
echo "   └─ ✅ IPv6 路由持久化服务已注册"

# ── 7. 使用 Python 生成所有配置文件和订阅链接 ────────────────
echo ""
echo "⚙️  正在生成四个出口配置文件..."

python3 << 'PYEOF' - "$SOURCE_FILE" "$MAIN_ANCHOR_IPV4" "$MAIN_PUBLIC_IPV4" "$RESERVED_IPV4" "$MAIN_IPV6" "$RESERVED_IPV6" "$HOSTNAME_LABEL" "$MAIN_IPV6_GATEWAY"
import json
import sys
import copy
import base64
from urllib.parse import quote

source_file      = sys.argv[1]
anchor_ipv4      = sys.argv[2]
main_public_ipv4 = sys.argv[3]
reserved_ipv4    = sys.argv[4]
main_ipv6        = sys.argv[5]
reserved_ipv6    = sys.argv[6]
hostname         = sys.argv[7]
ipv6_gateway     = sys.argv[8]

CONFIG_DIR = "/etc/s-box"

# ── 加载原始配置 ──────────────────────────────────────────
try:
    with open(source_file, 'r', encoding='utf-8') as f:
        original_config = json.load(f)
except Exception as e:
    print(f'❌ 解析原始配置失败: {e}')
    sys.exit(1)

# ── 工具函数 ──────────────────────────────────────────────

def derive_x25519_pubkey(private_key_b64url):
    """从 X25519 私钥推导公钥"""
    try:
        from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
        from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
        pad = private_key_b64url + '=' * (-len(private_key_b64url) % 4)
        raw = base64.urlsafe_b64decode(pad)
        priv = X25519PrivateKey.from_private_bytes(raw)
        pub_raw = priv.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
        return base64.urlsafe_b64encode(pub_raw).rstrip(b'=').decode()
    except Exception as e:
        print(f"⚠️  公钥推导失败（{e}），pbk 将留空")
        return ""

def get_common_sni(config):
    """获取通用 SNI"""
    for inbound in config.get('inbounds', []):
        if inbound.get('type') == 'vmess':
            sni = inbound.get('tls', {}).get('server_name', '')
            if sni:
                return sni
    return "www.bing.com"

def shift_ports(config, offset):
    """将所有入站端口偏移指定量"""
    for inbound in config.get('inbounds', []):
        if 'listen_port' in inbound and isinstance(inbound['listen_port'], int):
            old = inbound['listen_port']
            inbound['listen_port'] = old + offset
            print(f"   端口: {old} -> {old + offset}")

def force_ipv4_listen(config):
    """强制所有入站监听 IPv4 (0.0.0.0)"""
    for inbound in config.get('inbounds', []):
        inbound['listen'] = '0.0.0.0'

def build_strict_ipv6_dns(bind_ipv6_addr):
    """
    构建严格纯 IPv6 DNS 配置
    - 全局策略: ipv6_only
    - 所有上游: ipv6_only
    - 独立缓存防污染
    - DNS 查询自身也走 IPv6 出口
    """
    return {
        "servers": [
            {
                "tag": "ipv6-dns-cloudflare",
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
        "final": "ipv6-dns-cloudflare",
        "strategy": "ipv6_only",
        "disable_cache": False,
        "independent_cache": True
    }

def build_strict_ipv6_route():
    """
    构建严格 IPv6 路由规则
    - 协议嗅探提取域名
    - DNS 劫持确保走本地 IPv6-only 解析器
    - 拒绝所有 IPv4 流量 (ip_version: 4)
    - 拒绝所有 IPv4 CIDR (0.0.0.0/0) 双重保险
    - 默认出口走 direct (已绑定 IPv6)
    - final 兜底拒绝
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
        "final": "block-out",
        "auto_detect_interface": False
    }

def build_ipv6_outbounds(bind_ipv6_addr):
    """
    构建严格 IPv6 出站
    - inet6_bind_address: 强制绑定指定 IPv6
    - bind_interface: 锁定 eth0
    - bind_address_no_port: 防止端口耗尽
    - tcp_multi_path: false 防止 MPTCP 泄漏
    - 不设置任何 inet4_bind_address
    - block 出站作为 final 兜底
    """
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
        },
        {
            "type": "block",
            "tag": "block-out"
        }
    ]
    return outbounds

def build_ipv4_outbounds(bind_ipv4_addr):
    """构建 IPv4 出站 (保留IPv4)"""
    outbounds = [
        {
            "type": "direct",
            "tag": "direct",
            "inet4_bind_address": bind_ipv4_addr,
            "udp_fragment": True
        }
    ]
    # 保留原始配置中的其他出站 (socks, warp 等)
    return outbounds

def apply_ipv6_config(config, bind_ipv6_addr):
    """
    将配置转换为严格 IPv6 出口模式
    """
    # 强制 IPv4 入口
    force_ipv4_listen(config)

    # 替换 DNS 为严格 IPv6-only
    config['dns'] = build_strict_ipv6_dns(bind_ipv6_addr)

    # 替换路由为严格 IPv6
    config['route'] = build_strict_ipv6_route()

    # 替换出站为严格 IPv6 绑定
    config['outbounds'] = build_ipv6_outbounds(bind_ipv6_addr)

    # 移除 endpoints (warp 等可能导致 IPv4 泄漏)
    if 'endpoints' in config:
        del config['endpoints']

    return config


# ── 生成实例2: 保留 IPv4 (端口+1) ────────────────────────
print("\n📋 实例2: 保留 IPv4 出口 (端口+1)")
config_rv4 = copy.deepcopy(original_config)
shift_ports(config_rv4, 1)

# 绑定出站到 Anchor IP
if anchor_ipv4:
    for outbound in config_rv4.get('outbounds', []):
        if outbound.get('tag') == 'direct' and outbound.get('type') == 'direct':
            outbound['inet4_bind_address'] = anchor_ipv4
            outbound['udp_fragment'] = True
            print(f"   出站绑定: {anchor_ipv4}")
            break

rv4_file = f"{CONFIG_DIR}/sb-reserved-v4.json"
with open(rv4_file, 'w', encoding='utf-8') as f:
    json.dump(config_rv4, f, indent=4, ensure_ascii=False)
print(f"   ✅ 已保存: {rv4_file}")


# ── 生成实例3: 主 IPv6 (端口+2) ──────────────────────────
print(f"\n📋 实例3: 主 IPv6 出口 (端口+2)")
print(f"   出口绑定: {main_ipv6}")
config_v6 = copy.deepcopy(original_config)
shift_ports(config_v6, 2)
apply_ipv6_config(config_v6, main_ipv6)

v6_file = f"{CONFIG_DIR}/sb-ipv6.json"
with open(v6_file, 'w', encoding='utf-8') as f:
    json.dump(config_v6, f, indent=4, ensure_ascii=False)
print(f"   ✅ 已保存: {v6_file}")


# ── 生成实例4: 保留 IPv6 (端口+3) ────────────────────────
print(f"\n📋 实例4: 保留 IPv6 出口 (端口+3)")
print(f"   出口绑定: {reserved_ipv6}")
config_rv6 = copy.deepcopy(original_config)
shift_ports(config_rv6, 3)
apply_ipv6_config(config_rv6, reserved_ipv6)

rv6_file = f"{CONFIG_DIR}/sb-reserved-v6.json"
with open(rv6_file, 'w', encoding='utf-8') as f:
    json.dump(config_rv6, f, indent=4, ensure_ascii=False)
print(f"   ✅ 已保存: {rv6_file}")


# ══════════════════════════════════════════════════════════
# 生成所有订阅链接
# ══════════════════════════════════════════════════════════

common_sni = get_common_sni(original_config)

def generate_links(config, public_ip, label_suffix):
    """从配置生成订阅链接列表"""
    links = []

    for inbound in config.get('inbounds', []):
        itype = inbound.get('type')
        port  = inbound.get('listen_port')
        tag   = inbound.get('tag', '').replace('-sb', '')
        label = f"{tag}-{hostname}-{label_suffix}"
        tls   = inbound.get('tls', {})
        sni   = tls.get('server_name', common_sni) or common_sni

        # 对于 IPv6 出口实例，客户端入口仍然是 IPv4
        # public_ip 用于订阅链接中的服务器地址（客户端连接用）
        connect_ip = public_ip

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
                "v": "2",
                "ps": vmess_label,
                "add": connect_ip,
                "port": str(port),
                "id": uuid,
                "aid": "0",
                "scy": "auto",
                "net": "ws",
                "type": "none",
                "host": sni,
                "path": path,
                "tls": "tls" if tls_on else "",
                "sni": sni if tls_on else "",
                "alpn": "",
                "fp": "",
                "insecure": "0"
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


# ── 收集所有订阅链接 ─────────────────────────────────────
all_sections = []

# 实例1: 主 IPv4 (原始 sb.json，不修改)
print(f"\n{'='*60}")
print(f"  📡 实例1: 主 IPv4 出口 | IP: {main_public_ipv4}")
print(f"{'='*60}")
links1 = generate_links(original_config, main_public_ipv4, "主IPv4")
for name, link in links1:
    print(f"  📌 {name}: {link[:80]}...")
all_sections.append(("实例1-主IPv4", main_public_ipv4, links1))

# 实例2: 保留 IPv4
print(f"\n{'='*60}")
print(f"  📡 实例2: 保留 IPv4 出口 | IP: {reserved_ipv4}")
print(f"{'='*60}")
links2 = generate_links(config_rv4, reserved_ipv4, "保留IPv4")
for name, link in links2:
    print(f"  📌 {name}: {link[:80]}...")
all_sections.append(("实例2-保留IPv4", reserved_ipv4, links2))

# 实例3: 主 IPv6 (客户端用 IPv4 连接，出口走 IPv6)
# 订阅链接中服务器地址仍用主 IPv4 (因为客户端无 IPv6)
print(f"\n{'='*60}")
print(f"  📡 实例3: 主 IPv6 出口 | 入口: {main_public_ipv4} | 出口: {main_ipv6}")
print(f"{'='*60}")
links3 = generate_links(config_v6, main_public_ipv4, "主IPv6")
for name, link in links3:
    print(f"  📌 {name}: {link[:80]}...")
all_sections.append(("实例3-主IPv6", f"入口:{main_public_ipv4} 出口:{main_ipv6}", links3))

# 实例4: 保留 IPv6 (客户端用 IPv4 连接，出口走保留 IPv6)
print(f"\n{'='*60}")
print(f"  📡 实例4: 保留 IPv6 出口 | 入口: {main_public_ipv4} | 出口: {reserved_ipv6}")
print(f"{'='*60}")
links4 = generate_links(config_rv6, main_public_ipv4, "保留IPv6")
for name, link in links4:
    print(f"  📌 {name}: {link[:80]}...")
all_sections.append(("实例4-保留IPv6", f"入口:{main_public_ipv4} 出口:{reserved_ipv6}", links4))


# ── 保存订阅链接文件 ─────────────────────────────────────
links_file = f"{CONFIG_DIR}/all-links.txt"
with open(links_file, 'w', encoding='utf-8') as f:
    f.write("# DigitalOcean 四出口节点订阅链接\n")
    f.write(f"# 生成时间: 见文件修改时间\n")
    f.write(f"# 节点标签: {hostname}\n\n")

    for section_name, section_ip, section_links in all_sections:
        f.write(f"{'#'*60}\n")
        f.write(f"# {section_name} | {section_ip}\n")
        f.write(f"{'#'*60}\n\n")
        for name, link in section_links:
            f.write(f"# {name}\n{link}\n\n")
        f.write("\n")

print(f"\n💾 所有订阅链接已保存至: {links_file}")

# 同时分别保存各实例链接
for idx, (section_name, section_ip, section_links) in enumerate(all_sections, 1):
    instance_file = f"{CONFIG_DIR}/links-instance{idx}.txt"
    with open(instance_file, 'w', encoding='utf-8') as f:
        f.write(f"# {section_name} | {section_ip}\n\n")
        for name, link in section_links:
            f.write(f"# {name}\n{link}\n\n")

print("💾 各实例链接也已分别保存")
PYEOF

if [ $? -ne 0 ]; then
    echo "❌ 配置文件或订阅链接生成失败"
    exit 1
fi

# ── 8. 配置 systemd 服务 ─────────────────────────────────────
echo ""
echo "⚙️  配置 systemd 服务..."

SERVICE_SOURCE="/etc/systemd/system/sing-box.service"
if [ ! -f "$SERVICE_SOURCE" ]; then
    echo "❌ 找不到源服务文件 $SERVICE_SOURCE"
    exit 1
fi

# 获取 sing-box 可执行文件路径
SINGBOX_BIN=$(grep -oP 'ExecStart=\K\S+' "$SERVICE_SOURCE" | head -1)
if [ -z "$SINGBOX_BIN" ]; then
    SINGBOX_BIN=$(which sing-box 2>/dev/null || echo "/usr/local/bin/sing-box")
fi

# 实例2: 保留 IPv4
SERVICE2="/etc/systemd/system/sing-box-reserved-v4.service"
sed "s|sb\.json|sb-reserved-v4.json|g" "$SERVICE_SOURCE" > "$SERVICE2"
# 修改 Description
sed -i 's/Description=.*/Description=sing-box Reserved IPv4 Instance/' "$SERVICE2"
echo "   ├─ ✅ sing-box-reserved-v4.service"

# 实例3: 主 IPv6
SERVICE3="/etc/systemd/system/sing-box-ipv6.service"
sed "s|sb\.json|sb-ipv6.json|g" "$SERVICE_SOURCE" > "$SERVICE3"
sed -i 's/Description=.*/Description=sing-box Main IPv6 Instance/' "$SERVICE3"
echo "   ├─ ✅ sing-box-ipv6.service"

# 实例4: 保留 IPv6
SERVICE4="/etc/systemd/system/sing-box-reserved-v6.service"
sed "s|sb\.json|sb-reserved-v6.json|g" "$SERVICE_SOURCE" > "$SERVICE4"
sed -i 's/Description=.*/Description=sing-box Reserved IPv6 Instance/' "$SERVICE4"
echo "   └─ ✅ sing-box-reserved-v6.service"

# ── 9. 验证配置文件 ──────────────────────────────────────────
echo ""
echo "🔍 验证配置文件语法..."

CONFIGS_TO_CHECK=(
    "/etc/s-box/sb-reserved-v4.json:保留IPv4"
    "/etc/s-box/sb-ipv6.json:主IPv6"
    "/etc/s-box/sb-reserved-v6.json:保留IPv6"
)

ALL_VALID=true
for item in "${CONFIGS_TO_CHECK[@]}"; do
    cfg="${item%%:*}"
    name="${item##*:}"
    if $SINGBOX_BIN check -c "$cfg" 2>/dev/null; then
        echo "   ├─ ✅ $name ($cfg)"
    else
        echo "   ├─ ❌ $name ($cfg) - 语法错误!"
        $SINGBOX_BIN check -c "$cfg" 2>&1 | head -5 | sed 's/^/   │  /'
        ALL_VALID=false
    fi
done

if [ "$ALL_VALID" = false ]; then
    echo ""
    echo "⚠️  部分配置文件验证失败，请检查后再启动服务"
    echo "   提示: 可能需要更新 sing-box 到最新版本以支持所有路由动作"
fi

# ── 10. 重载并启动服务 ───────────────────────────────────────
echo ""
echo "🚀 启动所有服务..."

systemctl daemon-reload

SERVICES=(
    "sing-box-reserved-v4:保留IPv4"
    "sing-box-ipv6:主IPv6"
    "sing-box-reserved-v6:保留IPv6"
)

for item in "${SERVICES[@]}"; do
    svc="${item%%:*}"
    name="${item##*:}"
    systemctl enable "$svc" >/dev/null 2>&1
    systemctl restart "$svc" 2>/dev/null
    sleep 1
    if systemctl is-active --quiet "$svc"; then
        echo "   ├─ ✅ $svc ($name) - 运行中"
    else
        echo "   ├─ ❌ $svc ($name) - 启动失败"
        journalctl -u "$svc" --no-pager -n 3 2>/dev/null | sed 's/^/   │  /'
    fi
done

# ── 11. 验证出口 IP ──────────────────────────────────────────
echo ""
echo "🔍 验证出口 IP 地址..."

# 验证主 IPv6 出口是否正确
echo "   ├─ 测试主 IPv6 出口..."
ACTUAL_V6=$(curl -6 -sf --connect-timeout 5 --max-time 10 https://api6.ipify.org 2>/dev/null || echo "无法获取")
echo "   │  期望: $MAIN_IPV6"
echo "   │  实际: $ACTUAL_V6"

if [ "$ACTUAL_V6" = "$MAIN_IPV6" ]; then
    echo "   │  ✅ 主 IPv6 出口正常"
elif [ "$ACTUAL_V6" = "$RESERVED_IPV6" ]; then
    echo "   │  ⚠️  出口为保留 IPv6 (可能默认路由已被修改)"
else
    echo "   │  ⚠️  出口 IPv6 与预期不符"
fi

# ── 12. 输出最终报告 ─────────────────────────────────────────
echo ""
echo "╔═══════════════════════════════════════════════════════╗"
echo "║          🎉 四出口配置完成！                          ║"
echo "╠═══════════════════════════════════════════════════════╣"
echo "║                                                       ║"
printf "║  实例1: 主IPv4     %-35s║\n" "| $MAIN_PUBLIC_IPV4 (原始)"
printf "║  实例2: 保留IPv4   %-35s║\n" "| $RESERVED_IPV4 (端口+1)"
printf "║  实例3: 主IPv6     %-35s║\n" "| $MAIN_IPV6 (端口+2)"
printf "║  实例4: 保留IPv6   %-35s║\n" "| $RESERVED_IPV6 (端口+3)"
echo "║                                                       ║"
echo "╠═══════════════════════════════════════════════════════╣"
echo "║  📁 配置文件:                                         ║"
echo "║     /etc/s-box/sb.json              (实例1-主IPv4)    ║"
echo "║     /etc/s-box/sb-reserved-v4.json  (实例2-保留IPv4)  ║"
echo "║     /etc/s-box/sb-ipv6.json         (实例3-主IPv6)    ║"
echo "║     /etc/s-box/sb-reserved-v6.json  (实例4-保留IPv6)  ║"
echo "║                                                       ║"
echo "║  🔗 订阅链接: /etc/s-box/all-links.txt               ║"
echo "║                                                       ║"
echo "║  ⚠️  IPv6实例严格模式:                                ║"
echo "║     • DNS 仅请求 AAAA 记录                            ║"
echo "║     • 所有 IPv4 流量被路由规则拒绝                    ║"
echo "║     • 出站强制绑定指定 IPv6 地址                      ║"
echo "║     • 纯IPv4网站将无法访问 (这是预期行为)             ║"
echo "║                                                       ║"
echo "╠═══════════════════════════════════════════════════════╣"
echo "║  🛠️  管理命令:                                        ║"
echo "║  systemctl status sing-box                 (主IPv4)   ║"
echo "║  systemctl status sing-box-reserved-v4     (保留IPv4) ║"
echo "║  systemctl status sing-box-ipv6            (主IPv6)   ║"
echo "║  systemctl status sing-box-reserved-v6     (保留IPv6) ║"
echo "║                                                       ║"
echo "║  journalctl -u sing-box-ipv6 -f            (查看日志) ║"
echo "║  cat /etc/s-box/all-links.txt              (查看链接) ║"
echo "╚═══════════════════════════════════════════════════════╝"
