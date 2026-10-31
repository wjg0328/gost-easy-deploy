# Gost 一键部署脚本

## 特点

- 自动配置 BBR、安装 Docker，部署带账号认证和 TLS 加密的 Gost HTTP/2 代理。
- 自动申请 Let's Encrypt 证书，每天检查续期。
- 交互式设置域名、账号和端口，容器异常退出自动重启。

## 准备事项

- **服务器**：一台具有公网 IP、使用 systemd 且内核支持 BBR 的 Debian / Ubuntu 服务器，具备 root 权限。
- **域名**：一个已解析到服务器公网 IP 的域名；使用 Cloudflare 时设为“仅 DNS”。
- **端口**：安全组和防火墙放行 TCP `80` 及代理端口（如 `443`）；`80` 在证书申请和续期时须空闲且公网可达，不能用作代理端口。
- **网络与客户端**：服务器能访问软件源、Docker 镜像仓库及 Let's Encrypt；本地准备兼容 Gost HTTP/2 的客户端。

## 使用方法

以 root 登录后执行以下命令，将 `YOUR_USERNAME`、`YOUR_REPOSITORY` 替换为 GitHub 用户名和仓库名（分支不是 `main` 时也需替换）：

```bash
apt-get update
apt-get install -y curl ca-certificates cron
systemctl enable --now cron
curl -fL "https://raw.githubusercontent.com/YOUR_USERNAME/YOUR_REPOSITORY/main/gost-install.sh" -o gost-install.sh && bash gost-install.sh
```

执行后，按提示依次输入：

- **域名**：已解析到服务器的域名，如 `proxy.example.com`，不带 `https://`。
- **账号**：自行设置代理登录用户名，不能为空。
- **密码**：自行设置并再次输入确认，建议至少 20 位随机字母和数字；输入时不显示字符。
- **代理端口**：选择空闲且已放行的端口，如 `443`，不要使用 `80`。

## 免责声明

仅供合法用途，请遵守适用法律法规及服务商条款。脚本会修改系统配置，运行前请审查源码并备份。本项目按“现状”提供，不作安全性或稳定性保证；使用风险由使用者自行承担，作者在法律允许范围内不对相关损失负责。