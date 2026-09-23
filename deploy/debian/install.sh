#!/usr/bin/env bash
#
# 把 webrdp 部署到 Debian：建系统用户、同步代码、装依赖、装 systemd 单元。
#
# 用法（在项目目录里）：
#     sudo bash deploy/debian/install.sh
#
# 脚本不会自动启动服务 —— 避免用模板里的占位口令把服务直接暴露出去。
#
set -euo pipefail

APP_DIR=/opt/webrdp
SERVICE_NAME=webrdp
ENV_FILE=/etc/webrdp.env
RUN_USER=webrdp

log()  { printf '\033[32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "需要 root：sudo bash $0"

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[ -f "$SRC_DIR/server.js" ] || die "在 $SRC_DIR 找不到 server.js，脚本位置不对？"

# ---- 1. 检查 Node ----
if ! command -v node >/dev/null 2>&1; then
    die "未找到 node。请先安装 Node.js 18+（Debian 仓库自带版本可能过旧）：
      curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
      apt-get install -y nodejs"
fi
NODE_VER="$(node -p 'process.versions.node')"
NODE_MAJOR="${NODE_VER%%.*}"
[ "$NODE_MAJOR" -ge 18 ] || die "Node 版本过低（$NODE_VER），需要 18 及以上"
log "node $NODE_VER"

# ---- 2. 系统用户 ----
if id -u "$RUN_USER" >/dev/null 2>&1; then
    log "系统用户 $RUN_USER 已存在"
else
    useradd --system --home-dir "$APP_DIR" --shell /usr/sbin/nologin "$RUN_USER"
    log "已创建系统用户 $RUN_USER"
fi

# ---- 3. 同步代码 ----
mkdir -p "$APP_DIR"
if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete \
        --exclude 'node_modules' --exclude '.git' --exclude 'snapshots' --exclude '*.log' \
        "$SRC_DIR"/ "$APP_DIR"/
else
    warn "没有 rsync，改用 cp（不会清理已存在的旧文件）"
    cp -r "$SRC_DIR"/. "$APP_DIR"/
    rm -rf "$APP_DIR/node_modules" "$APP_DIR/.git" "$APP_DIR/snapshots"
fi
chown -R "$RUN_USER:$RUN_USER" "$APP_DIR"
log "代码已同步到 $APP_DIR"

# ---- 4. 依赖 ----
cd "$APP_DIR"
if [ -f package-lock.json ]; then
    npm ci --omit=dev --no-audit --no-fund
else
    npm install --omit=dev --no-audit --no-fund
fi
chown -R "$RUN_USER:$RUN_USER" "$APP_DIR"
log "依赖安装完成"

# ---- 5. 环境变量文件 ----
if [ -f "$ENV_FILE" ]; then
    chmod 600 "$ENV_FILE"
    log "$ENV_FILE 已存在，未覆盖"
else
    cp "$SRC_DIR/deploy/debian/webrdp.env.example" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    warn "已生成 $ENV_FILE（含占位口令），请先编辑再启动"
fi

# ---- 6. systemd ----
install -m 644 "$SRC_DIR/deploy/debian/$SERVICE_NAME.service" "/etc/systemd/system/$SERVICE_NAME.service"
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
log "systemd 单元已安装，并设为开机自启"

cat <<'EOF'

  下一步
  ------
    nano /etc/webrdp.env              # 改登录口令、配置 RDP_TARGETS
    systemctl restart webrdp
    systemctl status webrdp --no-pager
    journalctl -u webrdp -f

  浏览器打开 http://<本机IP>:8080/

  别忘了：被控机的 RDP 端口要对该服务器放行
  （在目标机上为网关放行该端口即可）

EOF
