// openbox-gateway.mjs —— fnOS 同源网关（Unix socket → 本地面板代理）
//
// 背景：fnOS 应用中心用 iframe 打开应用。声明了 gatewaySocket 的应用，fnOS 把
// https://<nas>/app/fnnas.openbox/<path> 转发到应用目录下的 Unix socket（路径
// **带前缀**，见 fnsoar admin_server.py 的 _strip_gateway_prefix）；本代理剥掉
// 前缀后转发到本地面板（默认 127.0.0.1:3036），HTTP 与 WebSocket 都转发。
// 没有它，HTTPS 的 fnOS 页面嵌 http://<ip>:3036 会被浏览器判为混合内容而拦截，
// 表现为应用中心打开后长时间白屏。
//
// 由 openbox-supervise 后台拉起；socket 路径 $ROOT/openbox.sock（对齐 fnsoar 的
// /vol1/@appcenter/<appname>/<name>.sock）。

import http from 'node:http'
import net from 'node:net'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = process.env.OPENBOX_ROOT
  || path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..')
const PREFIX = process.env.OPENBOX_GATEWAY_PREFIX || '/app/fnnas.openbox'
const SOCK = process.env.OPENBOX_GATEWAY_SOCK || path.join(ROOT, 'openbox.sock')
const DATA = path.join(ROOT, 'data')

// 面板端口：v0.1.319 起面板进程只听内网端口 3037（对外端口由 openbox-front.mjs
// 前置代理把守，它同时把 /api/fnoscf/* 分流给隧道助手）。网关直连内层面板，
// 不经过前置代理——应用中心路径不依赖前置代理的存活。三处约定必须一致：
// openbox-panel-run / openbox-front.mjs / openbox-gateway.mjs。
const port = Number(process.env.OPENBOX_PANEL_INTERNAL_PORT || 3037)

const strip = (url) => {
  if (url === PREFIX) return '/'
  if (url.startsWith(PREFIX + '/')) return url.slice(PREFIX.length)
  return url
}

// /api/fnoscf/* → 本机 Cloudflare 隧道助手(:3999)，路径重写成助手的 /api/*。
// 动机：面板服务端从 v0.1.326 起是带完整性清单的 minified bundle，不能打补丁加
// 代理路由；隧道卡片的 API 改走本网关转发（同源相对路径），fnOS 应用中心 iframe
// 与 fnos.net 远程域名打开面板时都不受混合内容策略限制。助手不在时返回 502。
const CF_HELPER_PORT = Number(process.env.CF_TUNNEL_PORT || 3999)
const cfRoute = (path) => {
  if (path === '/api/fnoscf' || path.startsWith('/api/fnoscf/')) {
    return '/api' + path.slice('/api/fnoscf'.length)
  }
  return null
}

const log = (m) => console.log(`[gateway] ${m}`)

const server = http.createServer((req, res) => {
  const stripped = strip(req.url)
  const cfPath = cfRoute(stripped)
  const opts = {
    host: '127.0.0.1',
    port: cfPath ? CF_HELPER_PORT : port,
    method: req.method,
    path: cfPath || stripped,
    headers: { ...req.headers, host: `127.0.0.1:${cfPath ? CF_HELPER_PORT : port}` },
  }
  const preq = http.request(opts, (pres) => {
    res.writeHead(pres.statusCode, pres.headers)
    pres.pipe(res)
  })
  preq.on('error', (e) => {
    if (!res.headersSent) res.writeHead(502, { 'Content-Type': 'text/plain; charset=utf-8' })
    res.end(cfPath
      ? `openbox gateway: cf-tunnel helper unreachable (${e.message})`
      : `openbox gateway: panel unreachable (${e.message})`)
  })
  req.pipe(preq)
})

// WebSocket 升级透传（面板的日志/流量实时通道）
server.on('upgrade', (req, socket, head) => {
  const up = net.connect(port, '127.0.0.1', () => {
    const lines = [`${req.method} ${strip(req.url)} HTTP/1.1`]
    for (let i = 0; i < req.rawHeaders.length; i += 2) {
      const k = req.rawHeaders[i]
      if (k.toLowerCase() === 'host') continue
      lines.push(`${k}: ${req.rawHeaders[i + 1]}`)
    }
    lines.push(`Host: 127.0.0.1:${port}`, '', '')
    up.write(lines.join('\r\n'))
    if (head && head.length) up.write(head)
    up.pipe(socket)
    socket.pipe(up)
  })
  up.on('error', () => socket.destroy())
  socket.on('error', () => up.destroy())
})

try { fs.unlinkSync(SOCK) } catch {}
server.listen(SOCK, () => {
  fs.chmodSync(SOCK, 0o666)
  // pidfile：监管器关闭时按它杀网关本体
  try { fs.writeFileSync(path.join(DATA, 'gateway.pid'), String(process.pid)) } catch {}
  log(`listening ${SOCK} → 127.0.0.1:${port} (prefix ${PREFIX})`)
})
server.on('error', (e) => log(`ERROR ${e.message}`))
process.on('exit', () => {
  try { fs.unlinkSync(path.join(DATA, 'gateway.pid')) } catch {}
})
