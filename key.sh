#!/bin/bash
# 用法: bash key.sh -g <GitHub用户名> [-p 端口] [-d]
set -u

GH_USER=""
SSH_PORT="22"
DISABLE_PASSWORD="no"
SSHD_CONFIG="/etc/ssh/sshd_config"

usage() {
    echo "用法: $0 -g <GitHub用户名> [-p 端口] [-d]"
    echo "  -g / -o  GitHub 用户名（必填）"
    echo "  -p       SSH 端口（默认 22）"
    echo "  -d       禁用密码登录"
    exit 1
}

while getopts "o:g:p:d" opt; do
    case $opt in
        o|g) GH_USER="$OPTARG" ;;
        p) SSH_PORT="$OPTARG" ;;
        d) DISABLE_PASSWORD="yes" ;;
        *) usage ;;
    esac
done

# 0. 基础检查
if [ "$(id -u)" -ne 0 ]; then
    echo "❌ 请使用 root 权限运行（sudo）"
    exit 1
fi

if [ -z "$GH_USER" ]; then
    echo "❌ 必须用 -g 指定 GitHub 用户名"
    usage
fi

if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || [ "$SSH_PORT" -lt 1 ] || [ "$SSH_PORT" -gt 65535 ]; then
    echo "❌ 端口必须是 1-65535 的数字"
    exit 1
fi

if ! command -v sshd >/dev/null 2>&1 && [ ! -x /usr/sbin/sshd ]; then
    echo "❌ 未找到 sshd，请先安装 openssh-server"
    exit 1
fi
SSHD_BIN=$(command -v sshd || echo /usr/sbin/sshd)

echo "========== 开始安全配置 SSH =========="

# 1. 下载并校验公钥
echo "正在从 GitHub 获取用户 [ $GH_USER ] 的公钥..."
TMP_KEYS=$(mktemp)
trap 'rm -f "$TMP_KEYS" "${TMP_KEYS}.valid"' EXIT

if ! curl -fsSL --max-time 15 "https://github.com/${GH_USER}.keys" -o "$TMP_KEYS"; then
    echo "❌ 下载失败：请检查用户名或网络（未做任何修改）"
    exit 1
fi

# 只保留合法的公钥行
grep -E '^(ssh-(rsa|ed25519)|ecdsa-sha2-|sk-)' "$TMP_KEYS" > "${TMP_KEYS}.valid" || true
mv "${TMP_KEYS}.valid" "$TMP_KEYS"

if [ ! -s "$TMP_KEYS" ]; then
    echo "❌ 该 GitHub 账号下没有可用的 SSH 公钥，已中止（未做任何修改）"
    exit 1
fi

mkdir -p ~/.ssh && chmod 700 ~/.ssh
touch ~/.ssh/authorized_keys

# 去重追加
while IFS= read -r key; do
    grep -qxF "$key" ~/.ssh/authorized_keys || echo "$key" >> ~/.ssh/authorized_keys
done < "$TMP_KEYS"
chmod 600 ~/.ssh/authorized_keys
echo "✅ 成功导入 GitHub 公钥（共 $(wc -l < "$TMP_KEYS") 个）"

# 2. 备份配置
BACKUP="${SSHD_CONFIG}.bak.$(date +%F-%H%M%S)"
cp "$SSHD_CONFIG" "$BACKUP"
echo "已备份配置到 $BACKUP"

# 3. 修改端口
echo "正在将 SSH 端口修改为: $SSH_PORT"
if grep -qE "^#?Port " "$SSHD_CONFIG"; then
    sed -i -E "s/^#?Port .*/Port $SSH_PORT/" "$SSHD_CONFIG"
else
    echo "Port $SSH_PORT" >> "$SSHD_CONFIG"
fi

# 4. 禁用密码登录
if [ "$DISABLE_PASSWORD" = "yes" ]; then
    echo "正在禁用密码登录，强制开启密钥登录..."
    for opt_name in PasswordAuthentication KbdInteractiveAuthentication; do
        if grep -qE "^#?${opt_name} " "$SSHD_CONFIG"; then
            sed -i -E "s/^#?${opt_name} .*/${opt_name} no/" "$SSHD_CONFIG"
        else
            echo "${opt_name} no" >> "$SSHD_CONFIG"
        fi
    done
    if grep -qE "^#?PubkeyAuthentication " "$SSHD_CONFIG"; then
        sed -i -E "s/^#?PubkeyAuthentication .*/PubkeyAuthentication yes/" "$SSHD_CONFIG"
    else
        echo "PubkeyAuthentication yes" >> "$SSHD_CONFIG"
    fi

    # sshd 是「先出现的配置优先」，sshd_config.d 里的设置可能覆盖主文件
    if [ -d /etc/ssh/sshd_config.d ]; then
        for f in /etc/ssh/sshd_config.d/*.conf; do
            [ -e "$f" ] || continue
            cp "$f" "${f}.bak.$(date +%s)" 2>/dev/null || true
            sed -i -E 's/^\s*(PasswordAuthentication|KbdInteractiveAuthentication)\s+yes/\1 no/I' "$f"
        done
    fi
fi

# 5. 语法检查，失败则回滚
if ! "$SSHD_BIN" -t; then
    echo "❌ sshd 配置语法错误，已回滚"
    cp "$BACKUP" "$SSHD_CONFIG"
    exit 1
fi

# 6. 防火墙：自动放行新端口（仅在防火墙已启用时）
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "${SSH_PORT}/tcp" >/dev/null && echo "✅ ufw 已放行 ${SSH_PORT}/tcp"
fi
if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${SSH_PORT}/tcp" >/dev/null \
        && firewall-cmd --reload >/dev/null \
        && echo "✅ firewalld 已放行 ${SSH_PORT}/tcp"
fi
echo "⚠️  如果是云服务器，还需要在控制台「安全组」放行 TCP ${SSH_PORT}"

# 7. 重启服务（兼容 Ubuntu 22.10+ 的 ssh.socket）
echo "正在重启 SSH 服务..."
if systemctl is-active --quiet ssh.socket 2>/dev/null; then
    mkdir -p /etc/systemd/system/ssh.socket.d
    cat > /etc/systemd/system/ssh.socket.d/port.conf <<EOF
[Socket]
ListenStream=
ListenStream=${SSH_PORT}
EOF
    systemctl daemon-reload
    systemctl restart ssh.socket
fi

if systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null; then
    echo "✅ SSH 服务重启成功！"
else
    echo "⚠️ 自动重启失败，请手动运行: systemctl restart sshd（或 ssh）"
fi

# 8. 显示实际生效的配置
echo "---------- 实际生效的配置 ----------"
"$SSHD_BIN" -T 2>/dev/null | grep -E '^(port|passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication) ' || true
echo "---------- 当前监听端口 ----------"
ss -tlnp 2>/dev/null | grep -E 'sshd|:'"${SSH_PORT}"'\b' || true

echo "========== 配置完成！=========="
echo "👉 新端口: $SSH_PORT"
echo "👉 必须使用你在 GitHub 绑定的私钥才能登录"
echo "👉 ⚠️ 不要关闭当前终端！先新开一个窗口测试: ssh -p $SSH_PORT 用户名@服务器IP"
