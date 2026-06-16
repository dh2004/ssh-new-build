#!/bin/bash

# 默认参数
GH_USER=""
SSH_PORT="22"
DISABLE_PASSWORD="no"

# 解析用户输入的参数
while getopts "o:g:p:d" opt; do
  case $opt in
    o|g) GH_USER="$OPTARG" ;; # 获取 GitHub 用户名
    p) SSH_PORT="$OPTARG" ;;   # 获取自定义端口
    d) DISABLE_PASSWORD="yes" ;; # 是否禁用密码登录
  esac
done

if [ -z "$GH_USER" ]; then
    echo "错误：必须使用 -og 参数指定你的 GitHub 用户名！"
    exit 1
fi

echo "========== 开始安全配置 SSH =========="

# 1. 导入 GitHub 公钥
echo "正在从 GitHub 获取 $GH_USER 的公钥..."
mkdir -p ~/.ssh
chmod 700 ~/.ssh
# 下载公钥并写入
curl -fsSL "https://github.com/${GH_USER}.keys" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

if [ $? -eq 0 ] && [ -s ~/.ssh/authorized_keys ]; then
    echo "✅ 成功导入 GitHub 公钥！"
else
    echo "❌ 导入公钥失败，请检查 GitHub 用户名是否正确，或网络是否通畅！"
    exit 1
fi

# 2. 修改 SSH 端口
echo "正在将 SSH 端口修改为 $SSH_PORT..."
# 检查配置文件里是否已经有 Port 这一行
if grep -q "^Port" /etc/ssh/sshd_config; then
    sed -i "s/^Port.*/Port $SSH_PORT/g" /etc/ssh/sshd_config
else
    echo "Port $SSH_PORT" >> /etc/ssh/sshd_config
fi

# 3. 禁用密码登录（如果指定了 -d）
if [ "$DISABLE_PASSWORD" = "yes" ]; then
    echo "正在禁用密码登录，提升安全性..."
    sed -i "s/^#\?PasswordAuthentication.*/PasswordAuthentication no/g" /etc/ssh/sshd_config
    sed -i "s/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/g" /etc/ssh/sshd_config
fi

# 4. 重启 SSH 服务令配置生效
echo "正在重启 SSH 服务..."
if systemctl restart sshd; then
    echo "✅ SSH 服务重启成功！"
elif systemctl restart ssh; then
    echo "✅ SSH 服务重启成功！"
else
    echo "⚠️ 重启 SSH 服务失败，请手动运行 systemctl restart sshd"
fi

echo "========== 配置完成！ =========="
echo "请注意：以后登录服务器请使用端口: $SSH_PORT，且必须使用密钥登录！"
