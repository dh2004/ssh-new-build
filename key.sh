#!/bin/bash

# 默认参数
GH_USER=""
SSH_PORT="22"
DISABLE_PASSWORD="no"

# 解析用户输入的参数
while getopts "o:g:p:d" opt; do
  case $opt in
    o|g) GH_USER="$OPTARG" ;;   # 获取 GitHub 用户名
    p) SSH_PORT="$OPTARG" ;;     # 获取自定义端口
    d) DISABLE_PASSWORD="yes" ;; # 是否禁用密码登录
  esac
done

if [ -z "$GH_USER" ]; then
    echo "❌ 错误：必须使用 -og 参数指定你的 GitHub 用户名！"
    exit 1
fi

echo "========== 开始安全配置 SSH =========="

# 1. 导入 GitHub 公钥
echo "正在从 GitHub 获取用户 [ $GH_USER ] 的公钥..."
mkdir -p ~/.ssh
chmod 700 ~/.ssh

# 下载公钥并追加到授权文件中
curl -fsSL "https://github.com/${GH_USER}.keys" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

# 检查是否成功下载到了公钥
if [ $? -eq 0 ] && [ -s ~/.ssh/authorized_keys ]; then
    echo "✅ 成功导入 GitHub 公钥！"
else
    echo "❌ 错误：导入公钥失败！"
    echo "请检查：1. 你的 GitHub 用户名是否填对。 2. 你的 GitHub 是否已经添加了 SSH 公钥。"
    exit 1
fi

# 2. 修改 SSH 端口
echo "正在将 SSH 端口修改为: $SSH_PORT"
if grep -q "^Port" /etc/ssh/sshd_config; then
    sed -i "s/^Port.*/Port $SSH_PORT/g" /etc/ssh/sshd_config
else
    # 如果原本没有 Port 这一行，直接在末尾追加
    echo "Port $SSH_PORT" >> /etc/ssh/sshd_config
fi

# 3. 禁用密码登录（如果指定了 -d）
if [ "$DISABLE_PASSWORD" = "yes" ]; then
    echo "正在禁用密码登录，强制开启密钥登录..."
    # 兼容各种系统的不同写法，确保把密码登录关掉
    sed -i "s/^#\?PasswordAuthentication.*/PasswordAuthentication no/g" /etc/ssh/sshd_config
    sed -i "s/^#\?KbdInteractiveAuthentication.*/KbdInteractiveAuthentication no/g" /etc/ssh/sshd_config
    sed -i "s/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/g" /etc/ssh/sshd_config
fi

# 4. 重启 SSH 服务令配置生效
echo "正在重启 SSH 服务..."
if systemctl restart sshd; then
    echo "✅ SSH 服务重启成功！"
elif systemctl restart ssh; then
    echo "✅ SSH 服务重启成功！"
else
    echo "⚠️ 自动重启服务失败，请稍后手动运行: systemctl restart sshd"
fi

echo "========== 配置完成！ =========="
echo "👉 以后登录这台服务器，请使用端口: $SSH_PORT"
echo "👉 必须使用你在 GitHub 绑定的那个私钥才能登录！"
