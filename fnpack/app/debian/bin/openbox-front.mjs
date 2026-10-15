// openbox-front.mjs —— fnOS 面板前置代理（对外端口 → 内层面板 + 隧道助手分流）
//
// 背景：Cloudflare 隧道卡片的 API 要走同源相对路径 api/fnoscf/*。v0.1.317 时把
// 代理路由注入面板 index.mjs；v0.1.326 起上游把面板服务端打成带完整性清单的
// minified bundle，不能打补丁，曾改到本机网关（openbox-gateway.mjs）——但实测
// fnOS 应用中心(:5667)与 FN Connect(fnos.net)对 /api/* 的请求是直达面板服务
// 端口、不过网关 socket 的，网关方案覆盖不到这些路径。
//
// 方案：面板退到内网端口 3037（127.0.0.1 之外也可达，无妨），本代理守对外端口
// （data/panel-port，缺省 3036）：
//   · /api/fnoscf/*  → 重写成 /api/* 转发到本机隧道助手(:3999)
//   · 其余全部       → 转发到内层面板(127.0.0.1:3037)
// HTTP 与 WebSocket  upgrade 都转发。这样无论从局域网 IP、fnOS 应用中心还是
// fnos.net 域名打开面板，卡片的同源请求都能到达助手。
//
// 由 openbox-supervise 常驻拉起（与网关/助手同生命周期）。data/panel-port 变化时
// 主动退出，由监管器按新端口重启（open-box port 改端口后 3 秒内生效）。
import http from 'node:http'
import net from 'node:net'
import { readFileSync, existsSync, statSync, appendFileSync } from 'node:fs'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = process.env.OPENBOX_ROOT || join(fileURLToPath(import.meta.url), '..', '..', '..')
const DATA = join(ROOT, 'data')
const PORT_FILE = join(DATA, 'panel-port')
const PANEL_LOG = join(DATA, 'panel.log')

// 内层面板端口：面板进程（openbox-panel-run）固定监听 3037，对外端口才是
// panel-port。三处约定（panel-run / front / gateway）必须一致。
const PANEL_PORT = Number(process.env.OPENBOX_PANEL_INTERNAL_PORT || 3037)
const HELPER_PORT = Number(process.env.CF_TUNNEL_PORT || 3999)

const readExternalPort = () => {
  try {
    const n = Number(readFileSync(PORT_FILE, 'utf8').trim())
    if (Number.isInteger(n) && n > 0 && n < 65536) return n
  } catch {}
  return 3036
}

const cfRewrite = (path) => {
  if (path === '/api/fnoscf' || path.startsWith('/api/fnoscf/')) {
    return '/api' + path.slice('/api/fnoscf'.length)
  }
  return null
}

const log = (m) => {
  try {
    appendFileSync(PANEL_LOG, `[front] ${new Date().toISOString()} ${m}\n`)
  } catch {}
}

let externalPort = readExternalPort()

const server = http.createServer((req, res) => {
  const cfPath = cfRewrite(req.url || '/')
  const opts = {
    host: '127.0.0.1',
    port: cfPath ? HELPER_PORT : PANEL_PORT,
    method: req.method,
    path: cfPath || (req.url || '/'),
    headers: { ...req.headers, host: `127.0.0.1:${cfPath ? HELPER_PORT : PANEL_PORT}` },
  }
  const preq = http.request(opts, (pres) => {
    res.writeHead(pres.statusCode, pres.headers)
    pres.pipe(res)
  })
  preq.on('error', (e) => {
    if (!res.headersSent) res.writeHead(502, { 'Content-Type': 'text/plain; charset=utf-8' })
    res.end(cfPath
      ? `openbox front: cf-tunnel helper unreachable (${e.message})`
      : `openbox front: panel unreachable (${e.message})`)
  })
  req.pipe(preq)
})

// WebSocket upgrade 透传（面板的日志/流量实时通道走 /api/controller-ws）
server.on('upgrade', (req, socket, head) => {
  const cfPath = cfRewrite(req.url || '/')
  const target = cfPath ? HELPER_PORT : PANEL_PORT
  const up = net.connect(target, '127.0.0.1', () => {
    const lines = [`${req.method} ${cfPath || req.url} HTTP/1.1`]
    for (let i = 0; i < req.rawHeaders.length; i += 2) {
      const k = req.rawHeaders[i]
      if (k.toLowerCase() === 'host') continue
      lines.push(`${k}: ${req.rawHeaders[i + 1]}`)
    }
    lines.push(`Host: 127.0.0.1:${target}`, '', '')
    up.write(lines.join('\r\n'))
    if (head && head.length) up.write(head)
    up.pipe(socket)
    socket.pipe(up)
  })
  up.on('error', () => socket.destroy())
  socket.on('error', () => up.destroy())
})

server.listen(externalPort, '0.0.0.0', () => {
  console.log(`front proxy listening 0.0.0.0:${externalPort} → panel 127.0.0.1:${PANEL_PORT} (fnoscf → helper :${HELPER_PORT})`)
})

// 端口文件变化 → 退出让监管器按新端口重启（open-box port 改端口路径）
let lastStamp = existsSync(PORT_FILE) ? statSync(PORT_FILE).mtimeMs : 0
setInterval(() => {
  try {
    const stamp = existsSync(PORT_FILE) ? statSync(PORT_FILE).mtimeMs : 0
    if (stamp !== lastStamp) {
      console.log(`panel-port changed (${externalPort} → ${readExternalPort()}), exiting for supervisor restart`)
      process.exit(0)
    }
  } catch {}
}, 5000).unref()

process.on('SIGTERM', () => process.exit(0))
process.on('SIGINT', () => process.exit(0))
