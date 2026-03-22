#!/bin/bash

# ====================================================
# DigitalOcean 双开保留 IP 一键配置脚本 (适配 Ubuntu 24.04)
# 作用: 自动读取 DO Anchor IP，端口自动+1，自动绑定出站网卡，注册双开服务
# ====================================================

# 1. 检查是否使用 root 运行
if [ "$EUID" -ne 0 ]; then
  echo "❌ 请使用 root 权限运行此脚本 (请加 sudo)"
  exit 1
fi

echo "============================================="
echo "🚀 开始配置 DigitalOcean 保留 IP 双开环境..."
echo "============================================="

# 2. 自动获取 DigitalOcean 保留 IP 的内部锚点 IP (Anchor IP)
echo "🔍 正在向 DigitalOcean 元数据接口请求 Anchor IP..."
ANCHOR_IP=$(curl -s http://169.254.169.254/metadata/v1/interfaces/public/0/anchor_ipv4/address)

if [ -z "$ANCHOR_IP" ]; then
    echo "❌ 错误：无法获取 Anchor IP。请确认本机是 DigitalOcean 且已绑定 Reserved IP！"
    exit 1
fi
echo "✅ 成功获取内网锚点 IP: $ANCHOR_IP"

# 3. 检查原配置文件是否存在
SOURCE_FILE="/etc/s-box/sb.json"
TARGET_FILE="/etc/s-box/sb-reserved.json"

# 【修复】：补充了 if 和 [ 之间的空格
if [ ! -f "$SOURCE_FILE" ]; then
    echo "❌ 错误：找不到原配置文件 $SOURCE_FILE，请先使用甬哥脚本完成基础部署。"
    exit 1
fi

# 4. 利用内嵌 Python 脚本自动修改 JSON 配置
echo "⚙️  正在生成端口+1并绑定 $ANCHOR_IP 的专属配置文件..."

python3 -c "
import json
import sys

source_file = '$SOURCE_FILE'
target_file = '$TARGET_FILE'
anchor_ip = '$ANCHOR_IP'

try:
    with open(source_file, 'r', encoding='utf-8') as f:
        config = json.load(f)
except Exception as e:
    print(f'❌ 解析 JSON 失败: {e}')
    sys.exit(1)

# 端口 + 1
if 'inbounds' in config:
    for inbound in config['inbounds']:
        if 'listen_port' in inbound and isinstance(inbound['listen_port'], int):
            old_port = inbound['listen_port']
            inbound['listen_port'] = old_port + 1
            print(f\"✅ 端口自动修改成功: {old_port} -> {inbound['listen_port']}\")

# 绑定网卡与 UDP 优化
if 'outbounds' in config:
    for outbound in config['outbounds']:
        if outbound.get('tag') == 'direct' and outbound.get('type') == 'direct':
            outbound['inet4_bind_address'] = anchor_ip
            outbound['udp_fragment'] = True
            print(f\"✅ 出站网卡绑定成功: 锁定至 {anchor_ip}\")
            break

with open(target_file, 'w', encoding='utf-8') as f:
    json.dump(config, f, indent=4, ensure_ascii=False)
"

if [ $? -ne 0 ]; then
    echo "❌ 配置文件生成失败，请检查上面输出的错误。"
    exit 1
fi
echo "✅ 新配置文件已生成至: $TARGET_FILE"

# 5. 配置 systemd 服务 (sing-box-reserved)
echo "⚙️  配置双开系统服务..."
SERVICE_SOURCE="/etc/systemd/system/sing-box.service"
SERVICE_TARGET="/etc/systemd/system/sing-box-reserved.service"

if [ ! -f "$SERVICE_SOURCE" ]; then
    echo "❌ 错误：找不到源服务文件 $SERVICE_SOURCE"
    exit 1
fi

# 替换配置路径并输出为新服务
sed 's/sb.json/sb-reserved.json/g' "$SERVICE_SOURCE" > "$SERVICE_TARGET"

# 6. 重载并启动服务
systemctl daemon-reload
systemctl enable sing-box-reserved
systemctl restart sing-box-reserved

echo "============================================="
echo "🎉 任务完成！保留 IP 实例配置成功并已启动！"
echo "👉 你的副节点端口已全部自动 +1。"
echo "👉 如果主节点被重新安装/重置，只需再次运行此脚本即可一键恢复！"
echo "============================================="
