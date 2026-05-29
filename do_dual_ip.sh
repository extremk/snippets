#!/bin/bash
# ====================================================
# DigitalOcean 双开保留 IP 一键配置脚本 (适配 Ubuntu 20.04/22.04/24.04)
# 兼容 Python 3.8+ (不使用 f-string，确保旧系统兼容)
# 作用: 自动读取 DO Anchor IP，端口自动+1，绑定出站网卡，注册双开服务，生成订阅链接
# ====================================================

# 1. 检查是否使用 root 运行
if [ "$EUID" -ne 0 ]; then
  echo "❌ 请使用 root 权限运行此脚本 (请加 sudo)"
  exit 1
fi

echo "============================================="
echo "🚀 开始配置 DigitalOcean 保留 IP 双开环境..."
echo "============================================="

# 2. 同时获取 Anchor IP（出站绑定用）和 Reserved IP（订阅链接用）
echo "🔍 正在向 DigitalOcean 元数据接口请求 IP 信息..."

ANCHOR_IP=$(curl -s http://169.254.169.254/metadata/v1/interfaces/public/0/anchor_ipv4/address)
RESERVED_IP=$(curl -s http://169.254.169.254/metadata/v1/reserved_ip/ipv4/ip_address)
HOSTNAME=$(curl -s http://169.254.169.254/metadata/v1/hostname | cut -d'.' -f1 | tr '[:lower:]' '[:upper:]')

if [ -z "$ANCHOR_IP" ]; then
    echo "❌ 错误：无法获取 Anchor IP。请确认本机是 DigitalOcean 且已绑定 Reserved IP！"
    exit 1
fi

# 如果 Reserved IP 获取失败，回退到主公网 IP
if [ -z "$RESERVED_IP" ]; then
    RESERVED_IP=$(curl -s http://169.254.169.254/metadata/v1/interfaces/public/0/ipv4/address)
    echo "⚠️  未检测到 Reserved IP，使用主公网 IP: $RESERVED_IP"
else
    echo "✅ Reserved IP (订阅用): $RESERVED_IP"
fi

echo "✅ Anchor IP   (出站绑定): $ANCHOR_IP"
echo "✅ 节点标签后缀: $HOSTNAME"

# 3. 检查原配置文件是否存在
SOURCE_FILE="/etc/s-box/sb.json"
TARGET_FILE="/etc/s-box/sb-reserved.json"
LINKS_FILE="/etc/s-box/reserved-links.txt"

if [ ! -f "$SOURCE_FILE" ]; then
    echo "❌ 错误：找不到原配置文件 $SOURCE_FILE，请先使用甬哥脚本完成基础部署。"
    exit 1
fi

# 4. 生成 sb-reserved.json（端口+1，绑定出站网卡）
echo ""
echo "⚙️  正在生成端口+1并绑定 $ANCHOR_IP 的专属配置文件..."

python3 - "$SOURCE_FILE" "$TARGET_FILE" "$ANCHOR_IP" <<'PYEOF'
import json
import sys

source_file = sys.argv[1]
target_file = sys.argv[2]
anchor_ip   = sys.argv[3]

try:
    with open(source_file, 'r', encoding='utf-8') as f:
        config = json.load(f)
except Exception as e:
    print('❌ 解析 JSON 失败: %s' % e)
    sys.exit(1)

# 端口 + 1
if 'inbounds' in config:
    for inbound in config['inbounds']:
        if 'listen_port' in inbound and isinstance(inbound['listen_port'], int):
            old_port = inbound['listen_port']
            inbound['listen_port'] = old_port + 1
            print("✅ 端口自动修改成功: %d -> %d" % (old_port, inbound['listen_port']))

# 绑定网卡与 UDP 优化
if 'outbounds' in config:
    modified = False
    for outbound in config['outbounds']:
        if outbound.get('tag') == 'direct' and outbound.get('type') == 'direct':
            outbound['inet4_bind_address'] = anchor_ip
            outbound['udp_fragment'] = True
            print("✅ 出站网卡绑定成功: 锁定至 %s" % anchor_ip)
            modified = True
            break
    if not modified:
        print("⚠️ 警告：未找到 tag='direct' 的出站规则，请手动检查。")

with open(target_file, 'w', encoding='utf-8') as f:
    json.dump(config, f, indent=4, ensure_ascii=False)
PYEOF

if [ $? -ne 0 ]; then
    echo "❌ 配置文件生成失败，请检查上面输出的错误。"
    exit 1
fi
echo "✅ 新配置文件已生成至: $TARGET_FILE"

# 5. 生成订阅链接
echo ""
echo "🔗 正在根据 $TARGET_FILE 自动生成订阅链接..."

python3 - "$TARGET_FILE" "$RESERVED_IP" "$HOSTNAME" "$LINKS_FILE" <<'PYEOF'
import json
import sys
import base64
from urllib.parse import quote

config_file = sys.argv[1]
public_ip   = sys.argv[2]
hostname    = sys.argv[3]
links_file  = sys.argv[4]

try:
    with open(config_file, 'r', encoding='utf-8') as f:
        config = json.load(f)
except Exception as e:
    print('❌ 解析配置文件失败: %s' % e)
    sys.exit(1)

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
    except Exception as e:
        print("⚠️  公钥推导失败（%s），pbk 将留空，请手动填写。" % e)
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
    label = "%s-%s-备用IP" % (tag, hostname)
    tls   = inbound.get('tls', {})
    sni   = tls.get('server_name', common_sni) or common_sni

    # ── VLESS Reality ──────────────────────────────────────────────────
    if itype == 'vless':
        uuid     = inbound['users'][0]['uuid']
        flow     = inbound['users'][0].get('flow', 'xtls-rprx-vision')
        reality  = tls.get('reality', {})
        priv_key = reality.get('private_key', '')
        short_id = reality.get('short_id', [''])[0]
        pbk      = derive_x25519_pubkey(priv_key)
        link = (
            "vless://%s@%s:%s"
            "?encryption=none&flow=%s&security=reality"
            "&sni=%s&fp=chrome&pbk=%s&sid=%s"
            "&type=tcp&headerType=none#%s"
        ) % (uuid, public_ip, port, flow, sni, pbk, short_id, label)
        links.append(('VLESS Reality', link))

    # ── VMess WS ───────────────────────────────────────────────────────
    elif itype == 'vmess':
        uuid      = inbound['users'][0]['uuid']
        transport = inbound.get('transport', {})
        path      = transport.get('path', '')
        tls_on    = tls.get('enabled', False)
        vmess_obj = {
            "v":        "2",
            "ps":       "vm-ws-%s-备用IP" % hostname,
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
        vmess_json = json.dumps(vmess_obj, separators=(',', ': '), ensure_ascii=False)
        encoded = base64.b64encode(vmess_json.encode()).decode()
        links.append(('VMess WS', "vmess://" + encoded))

    # ── Hysteria2 ──────────────────────────────────────────────────────
    elif itype == 'hysteria2':
        password = inbound['users'][0]['password']
        link = (
            "hysteria2://%s@%s:%s"
            "?sni=%s&alpn=h3&insecure=1&allowInsecure=1#%s"
        ) % (password, public_ip, port, sni, label)
        links.append(('Hysteria2', link))

    # ── TUIC v5 ────────────────────────────────────────────────────────
    elif itype == 'tuic':
        uuid     = inbound['users'][0]['uuid']
        password = inbound['users'][0]['password']
        auth     = quote("%s:%s" % (uuid, password), safe='')
        link = (
            "tuic://%s@%s:%s"
            "?sni=%s&alpn=h3&insecure=1&allowInsecure=1&congestion_control=bbr#%s"
        ) % (auth, public_ip, port, sni, label)
        links.append(('TUIC v5', link))

    # ── AnyTLS ─────────────────────────────────────────────────────────
    elif itype == 'anytls':
        password = inbound['users'][0]['password']
        link = (
            "anytls://%s@%s:%s"
            "?security=tls&sni=%s&insecure=1&allowInsecure=1&type=tcp#%s"
        ) % (password, public_ip, port, sni, label)
        links.append(('AnyTLS', link))

# ── 输出 ───────────────────────────────────────────────────────────────
print("\n" + "=" * 60)
print("  📡 Reserved IP: %s  |  节点标签: %s" % (public_ip, hostname))
print("=" * 60)

all_links_text = []
for name, link in links:
    print("\n📌 %s:" % name)
    print(link)
    all_links_text.append("# %s\n%s" % (name, link))

print("\n" + "-" * 60)

# 保存到文件
with open(links_file, 'w', encoding='utf-8') as f:
    f.write("# 保留 IP 节点订阅链接\n")
    f.write("# Reserved IP: %s\n\n" % public_ip)
    f.write("\n\n".join(all_links_text))
    f.write("\n")

print("💾 订阅链接已保存至: %s" % links_file)
PYEOF

if [ $? -ne 0 ]; then
    echo "❌ 订阅链接生成失败。"
    exit 1
fi

# 6. 配置 systemd 服务 (sing-box-reserved)
echo ""
echo "⚙️  配置双开系统服务..."
SERVICE_SOURCE="/etc/systemd/system/sing-box.service"
SERVICE_TARGET="/etc/systemd/system/sing-box-reserved.service"

if [ ! -f "$SERVICE_SOURCE" ]; then
    echo "❌ 错误：找不到源服务文件 $SERVICE_SOURCE"
    exit 1
fi

sed 's/sb\.json/sb-reserved.json/g' "$SERVICE_SOURCE" > "$SERVICE_TARGET"

# 7. 重载并启动服务
systemctl daemon-reload
systemctl enable sing-box-reserved
systemctl restart sing-box-reserved

echo ""
echo "============================================="
echo "🎉 全部完成！保留 IP 双开实例已启动！"
echo "---------------------------------------------"
echo "📡 Reserved IP : $RESERVED_IP"
echo "🔗 订阅链接文件: $LINKS_FILE"
echo "👉 副节点端口已全部自动 +1"
echo "👉 主节点重置后，重新运行此脚本一键恢复"
echo "============================================="
