'use strict';
// 本地冒烟测试：手工构造一个 RDCleanPath 请求，验证网关到 RDP 服务端的整条链路
// （TCP 连接 + X.224 协商 + TLS 握手 + 证书回传），不依赖浏览器。

const WebSocket = require('ws');

// 用法：node test-proxy.js [port] [cookie] [dest] [blocked-dest]
//   port          默认 8080
//   cookie        可选的 Cookie 头原值，例如 "rdpgw_sid=xxxx"（启用登录后必须提供）
//   dest          期望连通的 RDP 目标，默认 127.0.0.1:3389
//   blocked-dest  期望被白名单拒绝的目标，默认 127.0.0.1:22
const PORT = process.argv[2] || '8080';
const COOKIE = process.argv[3] || '';
const DEST = process.argv[4] || '127.0.0.1:3389';
const BLOCKED = process.argv[5] || '127.0.0.1:22';

function derLen(n) {
    if (n < 0x80) return Buffer.from([n]);
    const bytes = [];
    let t = n;
    while (t > 0) { bytes.unshift(t & 0xff); t >>= 8; }
    return Buffer.from([0x80 | bytes.length, ...bytes]);
}
function derWrap(tag, content) {
    return Buffer.concat([Buffer.from([tag]), derLen(content.length), content]);
}
function derInt(n) {
    const bytes = [];
    let t = n;
    while (t > 0) { bytes.unshift(t & 0xff); t >>= 8; }
    if (bytes.length === 0) bytes.push(0);
    return derWrap(0x02, Buffer.from(bytes));
}
const derUtf8 = (s) => derWrap(0x0c, Buffer.from(s, 'utf-8'));
const derOctet = (b) => derWrap(0x04, b);

// 标准 RDP X.224 连接请求（TPKT + CR + 协商请求 TLS|CredSSP = 0x03）
// 19 字节：TPKT(4) + LI(1) + CR(1) + dst-ref(2) + src-ref(2) + class(1) + neg(8)
const X224 = Buffer.from('030000130ee000000000000100080003000000', 'hex');
console.log(`X.224 request bytes = ${X224.length} (expected 19)`);

function buildRequest(dest) {
    return derWrap(0x30, Buffer.concat([
        derWrap(0xa0, derInt(3390)),      // [0] version = 3389 + 1
        derWrap(0xa2, derUtf8(dest)),     // [2] destination
        derWrap(0xa6, derOctet(X224)),    // [6] x224_connection_pdu
    ]));
}

function attempt(dest) {
    return new Promise((resolve) => {
        const ws = new WebSocket(`ws://127.0.0.1:${PORT}/`, COOKIE ? { headers: { Cookie: COOKIE } } : undefined);
        let settled = false;
        const finish = (r) => { if (settled) return; settled = true; clearTimeout(timer); try { ws.close(); } catch (_) {} resolve(r); };
        const timer = setTimeout(() => finish({ dest, result: 'TIMEOUT' }), 15000);

        ws.on('open', () => { console.log(`  [${dest}] ws open, sending RDCleanPath request`); ws.send(buildRequest(dest)); });
        ws.on('message', (d) => {
            const b = Buffer.from(d);
            finish({ dest, result: 'RESPONSE', bytes: b.length, head: b.slice(0, 24).toString('hex') });
        });
        ws.on('error', (e) => finish({ dest, result: 'WS_ERROR', error: e.message }));
        ws.on('close', () => finish({ dest, result: 'CLOSED_WITHOUT_RESPONSE' }));
    });
}

(async () => {
    console.log(`== 1) allowed destination ${DEST} ==`);
    console.log('  ->', JSON.stringify(await attempt(DEST)));
    console.log(`== 2) blocked destination ${BLOCKED} ==`);
    console.log('  ->', JSON.stringify(await attempt(BLOCKED)));
})();
