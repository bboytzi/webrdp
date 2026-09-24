#!/usr/bin/env bash
#
# 把 webrdp 部署到 Debian / 主流 Linux：建系统用户、同步代码、装依赖、装 systemd 单元。
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
    die "未找到 node。请先安装 Node.js 18+（发行版自带版本可能过旧）：
      curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
      apt-get install -y nodejs"
fi
NODE_BIN="$(command -v node)"
NODE_VER="$("$NODE_BIN" -p 'process.versions.node')"
NODE_MAJOR="${NODE_VER%%.*}"
[ "$NODE_MAJOR" -ge 18 ] || die "Node 版本过低（$NODE_VER），需要 18 及以上"
log "node $NODE_VER  ($NODE_BIN)"

# ---- 2. 系统用户与用户组 ----
# 单元文件里写了 Group=webrdp，所以组必须存在：
# useradd --system 在部分发行版下不会自动建同名组，这里显式 --user-group + 兜底 groupadd。
if id -u "$RUN_USER" >/dev/null 2>&1; then
    log "系统用户 $RUN_USER 已存在"
else
    useradd --system --user-group --home-dir "$APP_DIR" --shell /usr/sbin/nologin "$RUN_USER"
    log "已创建系统用户 $RUN_USER"
fi
if ! getent group "$RUN_USER" >/dev/null 2>&1; then
    groupadd --system "$RUN_USER"
    log "已补建用户组 $RUN_USER"
fi

# ---- 3. 同步代码 ----
# 不复制 .env / config.cmd：它们属于"本机配置"，目标服务器上要单独配置。
# 否则会把源机器的口令与内网目标一起带过去。
if [ "$SRC_DIR" = "$APP_DIR" ]; then
    warn "源目录就是 $APP_DIR，跳过复制（就地部署）"
else
    mkdir -p "$APP_DIR"
    if command -v rsync >/dev/null 2>&1; then
        rsync -a --delete \
            --exclude 'node_modules' --exclude '.git' --exclude 'snapshots' \
            --exclude '.env' --exclude 'config.cmd' --exclude '*.log' \
            "$SRC_DIR"/ "$APP_DIR"/
    else
        warn "没有 rsync，改用 cp（并清掉不该带过去的本地文件）"
        cp -r "$SRC_DIR"/. "$APP_DIR"/
        rm -rf "$APP_DIR/node_modules" "$APP_DIR/.git" "$APP_DIR/snapshots" \
               "$APP_DIR/.env" "$APP_DIR/config.cmd"
    fi
    log "代码已同步到 $APP_DIR"
fi
chown -R "$RUN_USER:$RUN_USER" "$APP_DIR"

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
if ! command -v systemctl >/dev/null 2>&1; then
    warn "没找到 systemctl（容器里？）—— 可以这样手动前台运行："
    warn "  cd $APP_DIR && set -a && . $ENV_FILE && exec node server.js"
else
    UNIT_SRC="$SRC_DIR/deploy/debian/$SERVICE_NAME.service"
    TMP_UNIT="$(mktemp)"
    # 把实际解析到的 node 路径写进单元，避免假设 node 一定在 /usr/bin
    sed "s|^ExecStart=.*|ExecStart=$NODE_BIN server.js|" "$UNIT_SRC" > "$TMP_UNIT"
    install -m 644 "$TMP_UNIT" "/etc/systemd/system/$SERVICE_NAME.service"
    rm -f "$TMP_UNIT"
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
    log "systemd 单元已安装（ExecStart=$NODE_BIN），并设为开机自启"
fi

cat <<EOF

  下一步
  ------
    nano $ENV_FILE               # 改登录口令、配置 RDP_TARGETS
    systemctl restart $SERVICE_NAME
    systemctl status $SERVICE_NAME --no-pager
    journalctl -u $SERVICE_NAME -f

  浏览器打开 http://<本机IP>:8080/
  （看到启动横幅里的 "Version:" 和 "Auth: ENABLED" 才算正常）

  三件容易被忽略的事
  ------------------
  1) 被控机放行：Windows 上要为这台网关放行 RDP 端口（入站规则）
  2) 本机防火墙：放行浏览器访问的端口，例如
       ufw allow 8080/tcp          （Debian/Ubuntu）
       firewall-cmd --add-port=8080/tcp --permanent && firewall-cmd --reload
  3) npm 慢的话（国内服务器）：
       npm config set registry https://registry.npmmirror.com

EOF
