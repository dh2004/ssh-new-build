#!/bin/bash
# 用法: bash key.sh -g <GitHub用户名> [-p 端口] [-d]
# 支持: Debian / Ubuntu / Fedora / RHEL / Rocky / AlmaLinux / CentOS
set -u

GH_USER=""
SSH_PORT="22"
DISABLE_PASSWORD="no"
SSHD_CONFIG="/etc/ssh/sshd_config"
SOCKET_DROPIN="/etc/systemd/system/ssh.socket.d/port.conf"
D_BACKUPS=()
D_DONE=""

# 备份 sshd_config.d 里的文件（每个文件只备份一次，保证回滚能恢复原始内容）
backup_d_file() {
    local f="$1"
    case " $D_DONE " in *" $f "*) return ;; esac
    local bak="${f}.bak.$(date +%s)"
    cp "$f" "$bak"
    D_BACKUPS+=("$bak")
    D_DONE="$D_DONE $f"
}

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

# ---------- 0. 基础检查 ----------
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

SSHD_BIN=$(command -v sshd || echo /usr/sbin/sshd)
if [ ! -x "$SSHD_BIN" ]; then
    echo "❌ 未找到 sshd，请先安装 openssh-server"
    exit 1
fi

restart_ssh() {
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null
}

# 回滚：恢复所有配置并重启 sshd
rollback() {
    echo "↩️  正在回滚配置..."
    cp "$BACKUP" "$SSHD_CONFIG"
    for bak in ${D_BACKUPS[@]+"${D_BACKUPS[@]}"}; do
        cp "$bak" "${bak%.bak.*}"
    done
    if [ -f "$SOCKET_DROPIN" ]; then
        rm -f "$SOCKET_DROPIN"
        systemctl daemon-reload
        systemctl restart ssh.socket 2>/dev/null || true
    fi
    if restart_ssh; then
        echo "✅ 已恢复原配置，SSH 服务正常运行"
    else
        echo "⚠️ 回滚后服务重启失败，请手动检查: systemctl status sshd"
    fi
}

echo "========== 开始安全配置 SSH =========="

# ---------- 1. 下载并校验公钥 ----------
echo "正在从 GitHub 获取用户 [ $GH_USER ] 的公钥..."
TMP_KEYS=$(mktemp)
trap 'rm -f "$TMP_KEYS" "${TMP_KEYS}.valid"' EXIT

if ! curl -fsSL --max-time 15 "https://github.com/${GH_USER}.keys" -o "$TMP_KEYS"; then
    echo "❌ 下载失败：请检查用户名或网络（未做任何修改）"
    exit 1
fi

grep -E '^(ssh-(rsa|ed25519)|ecdsa-sha2-|sk-)' "$TMP_KEYS" > "${TMP_KEYS}.valid" || true
mv "${TMP_KEYS}.valid" "$TMP_KEYS"

if [ ! -s "$TMP_KEYS" ]; then
    echo "❌ 该 GitHub 账号下没有可用的 SSH 公钥，已中止（未做任何修改）"
    exit 1
fi

mkdir -p ~/.ssh && chmod 700 ~/.ssh
touch ~/.ssh/authorized_keys

while IFS= read -r key; do
    grep -qxF "$key" ~/.ssh/authorized_keys || echo "$key" >> ~/.ssh/authorized_keys
done < "$TMP_KEYS"
chmod 600 ~/.ssh/authorized_keys
echo "✅ 成功导入 GitHub 公钥（共 $(wc -l < "$TMP_KEYS") 个）"

# ---------- 2. 备份配置 ----------
BACKUP="${SSHD_CONFIG}.bak.$(date +%F-%H%M%S)"
cp "$SSHD_CONFIG" "$BACKUP"
echo "已备份配置到 $BACKUP"

# ---------- 3. 修改端口 ----------
echo "正在将 SSH 端口修改为: $SSH_PORT"
if grep -qE "^#?Port " "$SSHD_CONFIG"; then
    sed -i -E "s/^#?Port .*/Port $SSH_PORT/" "$SSHD_CONFIG"
else
    echo "Port $SSH_PORT" >> "$SSHD_CONFIG"
fi

# sshd 的 Port 可以叠加：sshd_config.d 里如果还有别的 Port，会同时监听多个端口
# 这里把它们注释掉，保证只监听你指定的端口
if [ -d /etc/ssh/sshd_config.d ]; then
    for f in /etc/ssh/sshd_config.d/*.conf; do
        [ -e "$f" ] || continue
        if grep -qE '^\s*Port\s+[0-9]+' "$f"; then
            backup_d_file "$f"
            sed -i -E 's/^(\s*Port\s+[0-9]+.*)$/# \1  # disabled by key.sh/' "$f"
            echo "已注释 $f 中冲突的 Port 配置"
        fi
    done
fi

# ---------- 4. 禁用密码登录 ----------
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
            if grep -qiE '^\s*(PasswordAuthentication|KbdInteractiveAuthentication)\s+yes' "$f"; then
                backup_d_file "$f"
                sed -i -E 's/^\s*(PasswordAuthentication|KbdInteractiveAuthentication)\s+yes/\1 no/I' "$f"
            fi
        done
    fi
fi

# ---------- 5. 语法检查 ----------
if ! "$SSHD_BIN" -t; then
    echo "❌ sshd 配置语法错误"
    rollback
    exit 1
fi

# ---------- 6. SELinux：允许 sshd 监听自定义端口 ----------
if [ "$SSH_PORT" != "22" ] && command -v getenforce >/dev/null 2>&1 \
   && [ "$(getenforce)" != "Disabled" ]; then
    echo "检测到 SELinux，正在放行端口 $SSH_PORT ..."
    if ! command -v semanage >/dev/null 2>&1; then
        (dnf install -y policycoreutils-python-utils || yum install -y policycoreutils-python-utils) >/dev/null 2>&1
    fi
    if command -v semanage >/dev/null 2>&1; then
        if semanage port -a -t ssh_port_t -p tcp "$SSH_PORT" 2>/dev/null \
           || semanage port -m -t ssh_port_t -p tcp "$SSH_PORT" 2>/dev/null; then
            echo "✅ SELinux 已允许 sshd 使用端口 $SSH_PORT"
        else
            echo "❌ SELinux 端口放行失败"
            rollback
            exit 1
        fi
    else
        echo "❌ 无法安装 semanage（policycoreutils-python-utils），无法放行 SELinux 端口"
        rollback
        exit 1
    fi
fi

# ---------- 7. 重启服务（兼容 Ubuntu 22.10+ 的 ssh.socket） ----------
echo "正在重启 SSH 服务..."
if systemctl is-active --quiet ssh.socket 2>/dev/null; then
    mkdir -p "$(dirname "$SOCKET_DROPIN")"
    cat > "$SOCKET_DROPIN" <<EOF
[Socket]
ListenStream=
ListenStream=${SSH_PORT}
EOF
    systemctl daemon-reload
    systemctl restart ssh.socket
fi

restart_ssh
sleep 2

# ---------- 8. 验证端口确实在监听，否则回滚 ----------
if ss -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${SSH_PORT}$"; then
    echo "✅ SSH 服务已在端口 $SSH_PORT 上监听"
else
    echo "❌ 端口 $SSH_PORT 没有在监听，新配置未生效"
    systemctl status sshd --no-pager -l 2>/dev/null | tail -8
    rollback
    exit 1
fi

# ---------- 9. 防火墙：确认 SSH 正常后才放行新端口 ----------
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "${SSH_PORT}/tcp" >/dev/null && echo "✅ ufw 已放行 ${SSH_PORT}/tcp"
fi
if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${SSH_PORT}/tcp" >/dev/null \
        && firewall-cmd --reload >/dev/null \
        && echo "✅ firewalld 已放行 ${SSH_PORT}/tcp"
fi
echo "⚠️  如果是云服务器，还需要在控制台「安全组」放行 TCP ${SSH_PORT}"

# ---------- 10. 显示实际生效的配置 ----------
echo "---------- 实际生效的配置 ----------"
"$SSHD_BIN" -T 2>/dev/null | grep -E '^(port|passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication) ' || true
echo "---------- 当前监听 ----------"
ss -tlnp 2>/dev/null | grep -E ":${SSH_PORT}\b" || true

echo "========== 配置完成！=========="
echo "👉 新端口: $SSH_PORT"
echo "👉 必须使用你在 GitHub 绑定的私钥才能登录"
echo "👉 ⚠️ 不要关闭当前终端！先新开一个窗口测试: ssh -p $SSH_PORT 用户名@服务器IP"
