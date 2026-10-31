#!/bin/bash
# ============================================================
# Gost 一键部署脚本
# 功能：启用 BBR + 安装 Docker + 申请 Let's Encrypt 证书 + 启动 Gost HTTP/2 代理
# 建议许可证：MIT
# 警告：请仅用于合法用途，使用者需自行遵守当地法律法规
# ============================================================

set -euo pipefail

VERSION="1.1.0"
WORK_DIR="${HOME}/gost"
LETSENCRYPT_DIR="${WORK_DIR}/letsencrypt"
LETSENCRYPT_LIB_DIR="${WORK_DIR}/varlib/letsencrypt"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

check_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    log_error "请以 root 用户身份运行此脚本。"
    exit 1
  fi
}

install_dependencies() {
  log_info "检查并安装必要依赖..."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y -qq curl ca-certificates gnupg lsb-release bc iproute2 >/dev/null
  else
    log_error "当前仅支持基于 apt 的系统（Debian/Ubuntu）。"
    exit 1
  fi
  log_ok "依赖安装完成。"
}

enable_bbr() {
  local kernel_version
  kernel_version=$(uname -r | awk -F. '{print $1"."$2}')

  if (( $(echo "${kernel_version} < 4.9" | bc -l) )); then
    log_error "当前内核版本为 ${kernel_version}，BBR 需要 4.9 或更高版本。"
    exit 1
  fi
  log_info "当前内核版本 ${kernel_version}，符合 BBR 要求。"

  # 检查是否已启用
  if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr && lsmod | grep -q bbr; then
    log_ok "BBR 已启用，跳过配置。"
    return 0
  fi

  local sysctl_conf="/etc/sysctl.conf"
  grep -q "^net.core.default_qdisc=fq" "${sysctl_conf}" || echo "net.core.default_qdisc=fq" >> "${sysctl_conf}"
  grep -q "^net.ipv4.tcp_congestion_control=bbr" "${sysctl_conf}" || echo "net.ipv4.tcp_congestion_control=bbr" >> "${sysctl_conf}"

  sysctl -p >/dev/null 2>&1 || true

  local congestion
  congestion=$(sysctl -n net.ipv4.tcp_congestion_control)
  if [[ "${congestion}" == "bbr" ]]; then
    log_ok "TCP 拥塞控制算法已成功设置为 BBR。"
  else
    log_error "设置 BBR 失败，请检查内核是否支持。"
    exit 1
  fi

  if lsmod | grep -q bbr; then
    log_ok "BBR 模块已成功加载。"
  else
    log_warn "BBR 模块未加载，可能需要重启后生效。"
  fi
}

install_docker() {
  if command -v docker >/dev/null 2>&1; then
    log_ok "Docker 已安装：$(docker --version)"
    systemctl enable --now docker >/dev/null 2>&1 || true
    return 0
  fi

  log_info "开始安装 Docker..."
  mkdir -p "${WORK_DIR}"
  curl -fsSL https://get.docker.com -o "${WORK_DIR}/get-docker.sh"
  sh "${WORK_DIR}/get-docker.sh"
  rm -f "${WORK_DIR}/get-docker.sh"

  systemctl enable --now docker

  if command -v docker >/dev/null 2>&1; then
    log_ok "Docker 安装成功：$(docker --version)"
  else
    log_error "Docker 安装失败。"
    exit 1
  fi
}

check_port_free() {
  local port=$1
  if ss -tuln | grep -q ":${port} "; then
    return 1  # 被占用
  fi
  return 0  # 空闲
}

run_server() {
  echo
  log_warn "请确保域名已正确解析到本服务器！"
  echo

  local DOMAIN USERNAME PASSWORD PASSWORD_CONFIRM PORT

  while true; do
    read -rp "请输入域名: " DOMAIN
    if [[ "${DOMAIN}" =~ ^([a-zA-Z0-9]([-a-zA-Z0-9]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
      break
    else
      log_error "域名格式不正确，请重新输入。"
    fi
  done

  read -rp "请输入 Gost 服务用户名: " USERNAME
  while [[ -z "${USERNAME}" ]]; do
    log_error "用户名不能为空。"
    read -rp "请输入 Gost 服务用户名: " USERNAME
  done

  while true; do
    read -rsp "请输入 Gost 服务密码: " PASSWORD
    echo
    read -rsp "请再次输入密码确认: " PASSWORD_CONFIRM
    echo
    if [[ "${PASSWORD}" == "${PASSWORD_CONFIRM}" ]]; then
      if [[ -z "${PASSWORD}" ]]; then
        log_error "密码不能为空。"
        continue
      fi
      break
    else
      log_error "两次输入的密码不一致，请重新输入。"
    fi
  done

  while true; do
    read -rp "请输入 Gost 服务端口 (1-65535): " PORT
    if [[ "${PORT}" =~ ^[1-9][0-9]{0,4}$ ]] && (( PORT >= 1 && PORT <= 65535 )); then
      if check_port_free "${PORT}"; then
        break
      else
        log_error "端口 ${PORT} 已被占用，请更换。"
      fi
    else
      log_error "端口号无效，请输入 1-65535 之间的数字。"
    fi
  done

  # 准备证书目录
  mkdir -p "${LETSENCRYPT_DIR}" "${LETSENCRYPT_LIB_DIR}"
  chmod 700 "${LETSENCRYPT_DIR}" "${LETSENCRYPT_LIB_DIR}"

  # 获取证书
  if [[ -f "${LETSENCRYPT_DIR}/live/${DOMAIN}/fullchain.pem" ]]; then
    log_ok "证书已存在，跳过申请。"
  else
    log_info "开始申请 Let's Encrypt 证书（需要 80 端口空闲）..."

    if ! check_port_free 80; then
      log_error "80 端口已被占用，无法使用 standalone 模式申请证书。"
      log_error "请先释放 80 端口或手动申请证书后重试。"
      exit 1
    fi

    docker run --rm \
      -p 80:80 \
      -v "${LETSENCRYPT_DIR}:/etc/letsencrypt" \
      -v "${LETSENCRYPT_LIB_DIR}:/var/lib/letsencrypt" \
      certbot/certbot certonly \
      --standalone \
      --register-unsafely-without-email \
      --agree-tos \
      -d "${DOMAIN}"

    if [[ ! -f "${LETSENCRYPT_DIR}/live/${DOMAIN}/fullchain.pem" ]]; then
      log_error "证书获取失败，请检查域名解析是否正确、80 端口是否通畅。"
      exit 1
    fi
    log_ok "证书申请成功。"
  fi

  # 设置证书自动续期（每天 0 点）
  local RENEW_CMD="docker run --rm -p 80:80 -v \"${LETSENCRYPT_DIR}:/etc/letsencrypt\" -v \"${LETSENCRYPT_LIB_DIR}:/var/lib/letsencrypt\" certbot/certbot renew --standalone --quiet"
  local CRON_MARKER="# gost-cert-renew-${DOMAIN}"

  # 清理旧任务后重新添加，避免重复
  (crontab -l 2>/dev/null | grep -v "gost-cert-renew-${DOMAIN}" || true) | crontab -
  (crontab -l 2>/dev/null; echo "0 0 * * * ${RENEW_CMD} ${CRON_MARKER}") | crontab -
  log_ok "已设置每天 0 点自动检查并续期证书。"

  # 启动 Gost 容器
  local CONTAINER_NAME="gost_${DOMAIN//./_}"

  if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    log_info "检测到已存在的容器 ${CONTAINER_NAME}，正在删除..."
    docker rm -f "${CONTAINER_NAME}" >/dev/null
  fi

  log_info "正在启动 Gost 服务..."

  docker run -d \
    --name "${CONTAINER_NAME}" \
    --restart unless-stopped \
    --network host \
    -v "${LETSENCRYPT_DIR}:/etc/letsencrypt:ro" \
    gogost/gost \
    -L "http2://${USERNAME}:${PASSWORD}@:${PORT}?certFile=/etc/letsencrypt/live/${DOMAIN}/fullchain.pem&keyFile=/etc/letsencrypt/live/${DOMAIN}/privkey.pem&probeResistance=code:400&knock=www.cloudflare.com"

  sleep 3

  if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo
    log_ok "Gost 服务已成功启动！"
    echo
    echo -e "${GREEN}========== 连接信息 ==========${NC}"
    echo -e "协议      : HTTP/2 (TLS)"
    echo -e "地址      : ${DOMAIN}"
    echo -e "端口      : ${PORT}"
    echo -e "用户名    : ${USERNAME}"
    echo -e "密码      : ********"
    echo -e "容器名称  : ${CONTAINER_NAME}"
    echo -e "${GREEN}==============================${NC}"
    echo
    log_info "客户端可使用支持 HTTP/2 代理的工具连接。"
    log_info "证书将每天自动检查续期。"
  else
    log_error "Gost 服务启动失败，请检查日志：docker logs ${CONTAINER_NAME}"
    exit 1
  fi
}

main() {
  clear
  echo -e "${BLUE}========================================${NC}"
  echo -e "${BLUE}   Gost 一键部署脚本 v${VERSION}${NC}"
  echo -e "${BLUE}========================================${NC}"
  echo

  check_root
  mkdir -p "${WORK_DIR}"
  install_dependencies
  enable_bbr
  install_docker
  run_server

  echo
  log_ok "全部完成！欢迎来到更广阔的网络世界。"
  echo
}

main "$@"