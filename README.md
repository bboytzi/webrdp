# webrdp

**在浏览器里打开 Windows 远程桌面。** 客户端零安装、零插件、不经过任何第三方云。

RDP 协议在浏览器里由 WebAssembly 实现（[IronRDP](https://github.com/Devolutions/IronRDP)），
服务端只有一个 Node 进程：把浏览器的 WebSocket 翻译成 RDP，再连到目标机。

适用场景：**访问端只能用浏览器**（不能安装软件、不能运行客户端程序），
同时又不希望把内网机器交给第三方云中转。

```
浏览器 ──HTTP/WebSocket──▶ webrdp 网关 ──RDP(TCP+TLS)──▶ Windows 机器
        （网页，零安装）              （你自己的一台机器）
```

## 特性

- **客户端零安装**：现代浏览器即可，无插件、无扩展、无客户端软件
- **不依赖第三方云**：整条链路都是你自己的机器
- **支持 NLA**：CredSSP 在浏览器里完成，目标机的 RDP 安全设置不需要改
- **服务端登录认证**：页面、静态资源、WebSocket 握手三层拦截
- **目标白名单**：多台被控机以清单配置，清单即白名单
- **不暴露目标地址**：页面下拉框只显示标签
- **可服务多台**：一台网关纳管多台 Windows 机器
- 分辨率可选预设或自定义、画面等比缩放、文件传输、剪贴板（需 HTTPS）

## 快速开始

要求 **Node.js 18+**。只需三步：

```bash
# 1) 取代码
git clone https://github.com/bboytzi/webrdp.git && cd webrdp

# 2) 装依赖
npm install --omit=dev

# 3) 配置并启动
cp .env.example .env      # Windows: copy .env.example .env
# 编辑 .env：设置登录口令与 RDP_TARGETS
node server.js
```

然后浏览器打开 `http://<网关地址>:8080/`，登录后从下拉框选目标、填该机的 Windows 账号密码即可。

Windows 上也可以直接双击 `start.cmd`（它会读 `.env`，也可用 `start.cmd 8081` 覆盖端口）。

### 部署到 Debian / Linux

```bash
cd webrdp
sudo bash deploy/debian/install.sh   # 建用户、同步到 /opt/webrdp、装依赖、装 systemd 单元
sudo nano /etc/webrdp.env           # 改口令与目标清单
sudo systemctl restart webrdp
```

`install.sh` **不会自动启动服务** —— 避免用模板里的占位口令把服务直接暴露出去。
部署包位于 `deploy/debian/`：

| 文件 | 说明 |
|---|---|
| `install.sh` | 建系统用户 `webrdp`、同步代码到 `/opt/webrdp`、`npm ci`、安装 systemd 单元 |
| `webrdp.service` | 单元文件，含基础加固（NoNewPrivileges / ProtectSystem / 清空 capabilities / 限制地址族） |
| `webrdp.env.example` | 环境变量模板，首次部署复制为 `/etc/webrdp.env`（权限 600） |

### 放在 HTTPS 后面

公网发布**必须**用 HTTPS：否则口令明文传输、`COOKIE_SECURE` 无处生效，
而且浏览器只在安全上下文里提供 `navigator.clipboard`（剪贴板同步依赖它）。

nginx 反代要点（WebSocket 必须显式转发，长连接别被超时掐断）：

```nginx
location / {
    proxy_pass http://127.0.0.1:8080;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
    proxy_read_timeout 12h;
    proxy_send_timeout 12h;
    proxy_buffering off;
}
```

上 HTTPS 后把 `.env` 里的 `COOKIE_SECURE=1` 打开。

## 配置参考

所有配置都在 `.env`（Windows / Linux 同一份格式）。优先级：
**真实环境变量 > `.env` > 代码内置默认值**。

| 变量 | 默认值 | 说明 |
|---|---|---|
| `PORT` | `8080` | 监听端口 |
| `HOST` | `0.0.0.0` | 绑定地址；`127.0.0.1` 表示仅本机 |
| `AUTH_USER` / `AUTH_PASS` | 空 | **两项都填才启用登录**。对公网开放前必须设置 |
| `COOKIE_SECURE` | 关 | 设为 `1` 给会话 cookie 加 `Secure`（HTTPS 时用） |
| `RDP_TARGETS` | 空 | 目标清单：`标签=主机:端口`，逗号分隔；**清单即白名单** |
| `RDP_ALLOWED_DESTS` | `127.0.0.1:3389` | 未用 `RDP_TARGETS` 时的白名单；配置了清单则忽略此项 |
| `NODE_EXE` | 空 | 仅 Windows 启动脚本使用：node 不在 PATH 时的完整路径 |

`.env` 示例：

```
AUTH_USER=admin
AUTH_PASS=一个足够长的随机口令
RDP_TARGETS=办公机=192.168.1.100:3389,测试机=192.168.1.101:3389
```

- `RDP_TARGETS` 省略端口时按 **3389** 处理
- 日志与启动横幅会打印实际生效的版本号、目标清单与认证状态，用来确认"跑的是哪一份"

## 安全模型

### 三层认证（缺一不可）

| 层 | 行为 |
|---|---|
| 页面 / 静态资源 | 未登录访问 `/` 重定向到 `/login`；其余路径 401 |
| **WebSocket 握手** | 未携带有效会话的连接**握手阶段直接 401**（`ws` 的 `verifyClient`） |
| WebSocket 处理器 | 进入代理前再校验一次会话 |

> 只保护页面而漏掉 WebSocket 是最常见的漏洞：别人用脚本直接连 WS 就能白用 RDP 代理。

其余细节：

- 会话是 `HttpOnly + SameSite=Strict` cookie，12 小时滑动过期（存在内存里，进程重启即需重新登录）
- 登录页样式内联，不依赖任何静态资源（其他资源都需要认证）
- 全局失败计数：连续 10 次失败锁定 10 分钟，每次失败额外延迟 0.8 秒。
  用全局而非按 IP，是因为经反向代理/端口转发后所有请求都来自 `127.0.0.1`，
  按 IP 限流没有意义。副作用是别人乱试也可能让你暂时登不进去，属于有意取舍。
- 响应头：`X-Frame-Options: DENY`、`nosniff`、`no-referrer`；登录页 `no-store`
- 静态资源**白名单**：只提供 `/`、`/style.css`、`/lib/*`、`/pkg/*`，其余一律 404
  （`README.md`、`server.js`、`package.json`、`.env`、`node_modules/` 都不会被提供）

### 目标白名单防的是什么

1. **跳板 / 横向移动**：否则网关就是"你让它连谁它就连谁"的 RDP 拨号器；
2. **开放代理**：还能被用来连公网任意 `host:port`，绕开出口管控；
3. **内网端口扫描**：代理会先 TCP 连接再走 X.224/TLS，成功/失败的差异就是探测能力。

**它不管什么**（容易误判）：白名单管的是"**能连到哪些机器**"，
登录认证管"**谁能连**"，而"**谁能连哪些机器**"（按人分权）需要额外的授权层。
换句话说：**任何能登录的人都能连清单里的所有机器**。另外白名单挡不住
"网关主机本身被攻破"——那属于主机加固的范畴。

### 网关是可信设备

网关会**终结 TLS**（这是 RDCleanPath 的设计：浏览器做不了 TCP + X.224 + TLS，
交给网关完成，网关把服务端证书链交给客户端校验，然后双向转发）。因此：

- **口令不会明文经过网关**：NLA/CredSSP 在 TLS 内走 NTLM 挑战/应答，口令不上线；
- **但会话内容（画面、键盘输入、文件）在网关处是明文可见的**。

所以网关应当**专用、最小化、及时打补丁**，不要和别的服务混跑。

## 已验证的链路

`npm test`（即 `node test-proxy.js`）会手工构造一个 RDCleanPath 请求，
验证网关到 RDP 服务端的整条协议链，不依赖浏览器：

```
✓ TCP connection established
✓ Sent X.224 Connection Request (19 bytes)
✓ Received X.224 Connection Confirm (19 bytes)
✓ TLS handshake completed
✓ Extracted 1 certificate(s)
✓ Sending RDCleanPath response (805 bytes) to browser
```

用法：`node test-proxy.js [port] [cookie] [dest] [blocked-dest]`

## 已知限制

- **会顶掉目标机当前登录的会话**：Windows 客户端版只允许一个交互式会话，
  用 RDP 连进去会把本机用户锁屏/踢下线 —— 这是 RDP 协议特性，与网关无关。
  需要"旁观不打扰"请改用截屏类方案。
- **剪贴板同步需要 HTTPS**（安全上下文）；`http://<IP>:8080` 下 `navigator.clipboard` 不可用，
  画面与键鼠不受影响。
- **WebSocket 必须打通**：企业侧代理若拦 `Upgrade` 会连不上。
- 会话存在内存里，进程重启后需要重新登录。

## 故障排查

**行尾是方向性的（两个方向都会踩）**

| 文件 | 必须是 | 症状 |
|---|---|---|
| `.cmd` / `.bat` | **CRLF** | cmd 解析错乱、中文变成乱码命令 |
| `.sh` / `.service` / `.env` | **LF** | `/usr/bin/env: bad interpreter`、systemd 解析失败 |

检查方法（**用 `tr`，不要用 grep** —— `grep -c $'\r'` 对纯 LF 文件也可能全行误报）：

```bash
tr -cd '\r' < 文件 | wc -c      # 0 = LF；等于行数 = CRLF
```

修回：转 LF 用 `sed -i 's/\r$//' 文件`，转 CRLF 用 `sed -i 's/$/\r/' 文件`。
用 `git clone` / `scp -r` 传输可保持字节原样。

**跨平台打包用 tar.gz，不要用 PowerShell 的 zip**
`Compress-Archive` 生成的 zip 内部是反斜杠路径（`lib\session.js`），
Linux 上解压会变成一堆带反斜杠的怪文件名。`snapshot.ps1` 会同时产出 zip 与 tar.gz：
Windows 还原用 zip，传 Linux 用 tar.gz。

**连不上目标机**
1. 目标机的 RDP 端口要对网关放行（Windows 防火墙一条入站规则）；
2. 清单里要写端口（或让它落到默认 3389）；
3. 看网关日志里的 `Destination not allowed` —— 说明目标不在白名单内。

## 版本与回滚

当前版本见 `VERSION` 文件第一行；运行时版本号会出现在启动横幅、页面标题旁和 `GET /version`（需登录）。

```bash
git log --oneline --decorate        # 版本历史
git restore --source=v2.0.0 -- .    # 回退到某个已发布版本
```

`snapshot.cmd`（Windows）会把整个目录（含 `node_modules` 与 `.env`）打成快照，
适合"整体还原"：关掉服务 → 把当前目录改名留底 → 解压快照 → 重启。

## 致谢与许可

本项目基于以下开源作品：

- [IronRDP](https://github.com/Devolutions/IronRDP)（Devolutions）—— Rust 实现的 RDP 协议栈，MIT / Apache-2.0
- [ironrdp-wasm](https://github.com/electerm/ironrdp-wasm) —— IronRDP 的 WebAssembly 构建与示例客户端，MIT
- [ws](https://github.com/websockets/ws)、[Express](https://expressjs.com/)、[express-ws](https://github.com/HenningM/express-ws)

`index.html`、`style.css` 与 `lib/` 下的浏览器端代码来自 ironrdp-wasm 的 `example/` 目录（MIT），
在其基础上增加了配置化、认证、白名单与界面调整。

本项目以 [MIT 许可](LICENSE) 发布，Copyright (c) 2026 bboytzi。

## English summary

**webrdp** is a clientless RDP web gateway. It lets a browser open a Windows desktop
without installing any client software, plugin, or extension — and without routing
through a third-party cloud.

- RDP is implemented in the browser via WebAssembly ([IronRDP](https://github.com/Devolutions/IronRDP))
- The server is a single Node.js process (HTTP + WebSocket relay to the target)
- Server-side login with three enforcement layers (page, static assets, WebSocket handshake)
- Server-side target allowlist; the browser only ever sees target labels
- Configured entirely through `.env`; nothing sensitive lives in the code

Read the Chinese sections above for full documentation, or the source — the code is small.
