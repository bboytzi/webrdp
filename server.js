'use strict';

const path = require('path');
const crypto = require('crypto');
const express = require('express');
const expressWs = require('express-ws');
const { handleConnection } = require('./lib/rdp-proxy');

// ── 配置加载 ──
// 优先级：真实环境变量 > 项目根目录的 .env > 代码内置默认值。
// .env 让 Windows / Linux / systemd 用同一份配置格式，
// 也让账号、口令、内网地址这些敏感项完全不进入代码仓库。
function loadDotEnv(file) {
    const fs = require('fs');
    if (!fs.existsSync(file)) return false;
    const text = fs.readFileSync(file, 'utf-8');
    for (const rawLine of text.split(/\r?\n/)) {
        const line = rawLine.trim();
        if (!line || line.startsWith('#')) continue;
        const eq = line.indexOf('=');
        if (eq <= 0) continue;
        const key = line.slice(0, eq).trim();
        let value = line.slice(eq + 1).trim();
        if (value.length >= 2 && ((value.startsWith('"') && value.endsWith('"')) ||
            (value.startsWith("'") && value.endsWith("'")))) {
            value = value.slice(1, -1);
        }
        if (!(key in process.env)) process.env[key] = value; // 真实环境变量优先
    }
    return true;
}

const DOTENV_LOADED = loadDotEnv(path.join(__dirname, '.env'));

const PORT = parseInt(process.env.PORT || '8080', 10);
const HOST = process.env.HOST || '0.0.0.0';
const ROOT = __dirname;
// 版本号来自 VERSION 文件第一行，用于启动横幅与页面显示（便于确认"跑的是哪一份"）
const VERSION = (() => {
    try {
        const fs = require('fs');
        const text = fs.readFileSync(path.join(ROOT, 'VERSION'), 'utf-8');
        return text.split(/\r?\n/)[0].trim() || 'unknown';
    } catch (_) {
        return 'unknown';
    }
})();
// ── 目标清单（多台被控机） ──
// RDP_TARGETS="标签=主机:端口,标签2=主机:端口"
// 未写端口时补默认 3389（与 rdp-proxy 里 parseDestination 的行为保持一致，
// 否则白名单会与实际拨号地址对不上）。
// 这里同时把白名单从目标清单推导出来 —— 一份配置即一处真相，
// 避免 RDP_TARGETS 和 RDP_ALLOWED_DESTS 两处不一致导致"配了却连不上"。
function parseTargets(raw) {
    if (!raw) return [];
    return raw.split(',')
        .map((item) => {
            const s = item.trim();
            if (!s) return null;
            const eq = s.indexOf('=');
            const label = (eq >= 0 ? s.slice(0, eq) : s).trim();
            let dest = (eq >= 0 ? s.slice(eq + 1) : s).trim();
            if (!label || !dest) return null;
            if (!/:\d+$/.test(dest)) dest = `${dest}:3389`;
            return { label, dest };
        })
        .filter(Boolean);
}

const TARGETS = parseTargets(process.env.RDP_TARGETS || '');
if (TARGETS.length > 0) {
    if (process.env.RDP_ALLOWED_DESTS) {
        console.log('[warn] RDP_TARGETS 已配置，将忽略 RDP_ALLOWED_DESTS（白名单从目标清单推导）');
    }
    process.env.RDP_ALLOWED_DESTS = TARGETS.map((t) => t.dest).join(',');
}

const LIB_DIR = path.join(ROOT, 'lib');
const PKG_DIR = path.join(ROOT, 'node_modules', 'ironrdp-wasm', 'pkg');

// ── Auth configuration ──
// Set both AUTH_USER and AUTH_PASS to require a login. Keep them unset only for
// LAN-only use. Never expose this port publicly with auth disabled.
const AUTH_USER = process.env.AUTH_USER || '';
const AUTH_PASS = process.env.AUTH_PASS || '';
const AUTH_ENABLED = Boolean(AUTH_USER && AUTH_PASS);
const COOKIE_NAME = 'rdpgw_sid';
const COOKIE_SECURE = process.env.COOKIE_SECURE === '1';
const SESSION_TTL_MS = 12 * 60 * 60 * 1000;

// Brute-force protection. A global counter is used on purpose: behind a
// reverse proxy or port forwarder every request appears to come from 127.0.0.1,
// so per-IP limits would be useless.
const MAX_FAILURES = 10;
const LOCK_MS = 10 * 60 * 1000;
const FAIL_DELAY_MS = 800;

const sessions = new Map();
let failCount = 0;
let lockedUntil = 0;

function purgeSessions() {
    const now = Date.now();
    for (const [token, s] of sessions) {
        if (now - s.lastSeen > SESSION_TTL_MS) sessions.delete(token);
    }
}

function createSession() {
    const token = crypto.randomBytes(32).toString('hex');
    sessions.set(token, { created: Date.now(), lastSeen: Date.now() });
    return token;
}

function readSession(token) {
    if (!token) return null;
    const s = sessions.get(token);
    if (!s) return null;
    if (Date.now() - s.lastSeen > SESSION_TTL_MS) {
        sessions.delete(token);
        return null;
    }
    s.lastSeen = Date.now();
    return s;
}

function parseCookies(header) {
    const out = {};
    if (!header) return out;
    for (const part of header.split(';')) {
        const i = part.indexOf('=');
        if (i < 0) continue;
        out[part.slice(0, i).trim()] = decodeURIComponent(part.slice(i + 1).trim());
    }
    return out;
}

function sessionFromReq(req) {
    return readSession(parseCookies(req.headers.cookie)[COOKIE_NAME]);
}

function safeEqual(a, b) {
    const A = Buffer.from(String(a), 'utf-8');
    const B = Buffer.from(String(b), 'utf-8');
    if (A.length !== B.length) return false;
    return crypto.timingSafeEqual(A, B);
}

function cookieHeader(token) {
    const parts = [
        `${COOKIE_NAME}=${token}`,
        'HttpOnly',
        'SameSite=Strict',
        'Path=/',
        `Max-Age=${Math.floor(SESSION_TTL_MS / 1000)}`,
    ];
    if (COOKIE_SECURE) parts.push('Secure');
    return parts.join('; ');
}

function clearCookieHeader() {
    const parts = [`${COOKIE_NAME}=`, 'HttpOnly', 'SameSite=Strict', 'Path=/', 'Max-Age=0'];
    if (COOKIE_SECURE) parts.push('Secure');
    return parts.join('; ');
}

const escapeHtml = (s) => String(s).replace(/[&<>"']/g, (c) => (
    { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]
));

// Self-contained login page: it must render without any other asset, because
// everything else (including /style.css) requires a session.
function loginPage(message) {
    return `<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>登录</title>
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body {
    background: #1a1a2e; color: #e0e0e0; min-height: 100vh;
    display: flex; align-items: center; justify-content: center;
    font-family: 'Segoe UI', system-ui, -apple-system, sans-serif;
  }
  form {
    background: #16213e; border: 1px solid #0f3460; border-radius: 10px;
    padding: 28px 32px; width: 320px; display: flex; flex-direction: column; gap: 12px;
  }
  h1 { font-size: 16px; font-weight: 600; color: #e94560; margin-bottom: 4px; }
  input {
    padding: 9px 12px; border-radius: 4px; border: 1px solid #0f3460;
    background: #1a1a2e; color: #e0e0e0; font-size: 14px;
  }
  input:focus { outline: none; border-color: #e94560; }
  button {
    margin-top: 4px; padding: 10px; border: none; border-radius: 4px;
    background: #e94560; color: #fff; font-size: 14px; font-weight: 600; cursor: pointer;
  }
  button:hover { background: #c73e54; }
  .err { color: #f85149; font-size: 12px; }
  .note { color: #6e7681; font-size: 11px; line-height: 1.5; }
</style>
</head>
<body>
<form method="POST" action="/login">
  <h1>远程桌面</h1>
  ${message ? `<p class="err">${escapeHtml(message)}</p>` : ''}
  <input name="username" placeholder="用户名" autocomplete="username" autofocus>
  <input name="password" type="password" placeholder="密码" autocomplete="current-password">
  <button type="submit">登录</button>
  <p class="note">连续输错 10 次会锁定 10 分钟。</p>
</form>
</body>
</html>`;
}

// ── App ──

const app = express();
app.disable('x-powered-by');

// Reject unauthenticated WebSocket upgrades at handshake time (HTTP 401),
// before any session is established.
expressWs(app, undefined, {
    wsOptions: {
        verifyClient: (info, cb) => {
            if (!AUTH_ENABLED) return cb(true);
            const ok = Boolean(readSession(parseCookies(info.req.headers.cookie)[COOKIE_NAME]));
            if (ok) return cb(true);
            cb(false, 401, 'Unauthorized');
        },
    },
});

app.use(express.urlencoded({ extended: false }));

app.use((_req, res, next) => {
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('X-Frame-Options', 'DENY');
    res.setHeader('Referrer-Policy', 'no-referrer');
    next();
});

// ── Public routes (no session required) ──

app.get('/login', (req, res) => {
    if (!AUTH_ENABLED || sessionFromReq(req)) return res.redirect('/');
    res.setHeader('Cache-Control', 'no-store');
    res.type('html').send(loginPage(lockedUntil > Date.now() ? '尝试次数过多，请稍后再试' : ''));
});

app.post('/login', async (req, res) => {
    if (!AUTH_ENABLED) return res.redirect('/');
    res.setHeader('Cache-Control', 'no-store');

    if (Date.now() < lockedUntil) {
        return res.status(429).type('html').send(loginPage('尝试次数过多，请稍后再试'));
    }

    const user = String((req.body && req.body.username) || '');
    const pass = String((req.body && req.body.password) || '');

    if (!safeEqual(user, AUTH_USER) || !safeEqual(pass, AUTH_PASS)) {
        failCount += 1;
        if (failCount >= MAX_FAILURES) {
            lockedUntil = Date.now() + LOCK_MS;
            failCount = 0;
            console.log('[auth] too many failures - locked for 10 minutes');
        }
        console.log(`[auth] failed login attempt (user="${user}")`);
        await new Promise((r) => setTimeout(r, FAIL_DELAY_MS));
        return res.status(401).type('html').send(loginPage('用户名或密码错误'));
    }

    failCount = 0;
    res.setHeader('Set-Cookie', cookieHeader(createSession()));
    console.log(`[auth] login ok (user="${user}")`);
    res.redirect('/');
});

app.get('/logout', (req, res) => {
    const token = parseCookies(req.headers.cookie)[COOKIE_NAME];
    if (token) sessions.delete(token);
    res.setHeader('Set-Cookie', clearCookieHeader());
    res.redirect('/login');
});

// ── Auth gate for everything below ──

app.use((req, res, next) => {
    if (!AUTH_ENABLED) return next();
    if (sessionFromReq(req)) return next();
    if (req.method === 'GET' && String(req.headers.accept || '').includes('text/html')) {
        return res.redirect('/login');
    }
    return res.status(401).type('text/plain').send('Unauthorized');
});

// ── Static assets: explicit allowlist only ──
// Serving the project root would publish README.md, server.js, package.json,
// server.log and the whole node_modules tree to anyone who can reach this port.

app.get('/', (_req, res) => res.sendFile(path.join(ROOT, 'index.html')));
app.get('/version', (_req, res) => res.type('text/plain').send(VERSION));

// 只回传标签与地址，前端下拉框显示标签（不把内网地址摆在页面上）。
// 地址仍然要下发，因为 WASM 客户端需要用真实地址建立会话；
// 服务端白名单始终是最终裁决点，客户端改不了。
app.get('/targets', (_req, res) => res.json(TARGETS));
app.get('/style.css', (_req, res) => res.sendFile(path.join(ROOT, 'style.css')));
app.get('/favicon.ico', (_req, res) => res.status(204).end());

app.use('/lib', express.static(LIB_DIR));

// The page imports '../pkg/rdp_client.js', which resolves to /pkg/… at the site root.
app.use('/pkg', express.static(PKG_DIR, {
    setHeaders(res, filePath) {
        if (filePath.endsWith('.wasm')) res.setHeader('Content-Type', 'application/wasm');
    },
}));

// ── WebSocket RDCleanPath proxy ──
// Second gate, on top of verifyClient: only an authenticated session may reach
// the proxy. Without this, anyone could bypass the page and dial RDP directly.

app.ws('/', (ws, req) => {
    if (AUTH_ENABLED && !sessionFromReq(req)) {
        console.log('[auth] WS rejected - no valid session');
        try { ws.close(4401, 'unauthorized'); } catch (_) {}
        return;
    }
    handleConnection(ws);
});

// ── Start ──

setInterval(purgeSessions, 10 * 60 * 1000).unref();

app.listen(PORT, HOST, () => {
    console.log(`\n  HTTP + WebSocket gateway on http://${HOST}:${PORT}/`);
    console.log(`  Version: v${VERSION}`);
    console.log('  Static: / (index.html), /style.css, /lib/*, /pkg/*  - nothing else');
    console.log(`  Allowed RDP targets: ${process.env.RDP_ALLOWED_DESTS || '127.0.0.1:3389 (default)'}`);
    if (TARGETS.length > 0) {
        console.log(`  Target list: ${TARGETS.length} host(s) - selectable in the browser`);
        for (const t of TARGETS) console.log(`    - ${t.label}  ->  ${t.dest}`);
    } else {
        console.log('  Target list: RDP_TARGETS not set - manual host input mode');
    }
    console.log(`  Config: ${DOTENV_LOADED ? '.env loaded' : 'no .env file (using environment variables only)'}`);
    if (AUTH_ENABLED) {
        console.log(`  Auth: ENABLED (user "${AUTH_USER}", session ${SESSION_TTL_MS / 3600000}h, secure-cookie ${COOKIE_SECURE})`);
    } else {
        console.log('  Auth: DISABLED - set AUTH_USER and AUTH_PASS before exposing this port publicly');
    }
    console.log('');
});
