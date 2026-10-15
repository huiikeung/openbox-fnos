#!/usr/bin/env node
// openbox-cf-tunnel —— Cloudflare 隧道助手（fnOS 本地 API）
//
// 由 openbox-supervise 常驻拉起（和面板/网关同生命周期），提供局域网内的
// 极简 HTTP API，供面板注入的「Cloudflare 隧道」卡片调用：
//   GET  /api/status → { running, url, mode, hasToken, hostname, pid, panelPort,
//                        stale, error, binaryOk, startedAt }
//   POST /api/start  → body {mode:'quick'|'named', token?, hostname?}
//                       quick: cloudflared tunnel --url http://127.0.0.1:<面板端口>
//                              （随机 trycloudflare.com 地址，重启即变）
//                       named: cloudflared tunnel run --token <token>
//                              （CF 账户+域名，地址固定；hostname 仅用于展示）
//   POST /api/stop   → 停止隧道
//
// 说明：
//   · 隧道目标固定为本机面板端口（data/panel-port，缺省 3036），因此隧道覆盖
//     面板 UI 与订阅分享（都是 HTTP）；Shadowsocks 等二进制协议不过 Cloudflare。
//   · 状态（含命名隧道 token）落盘 data/cf-tunnel.json；该文件在 appdata 内，
//     与面板 sqlite（含 SS 密码）同信任级别。
//   · 本机到 Cloudflare 边缘的 QUIC(UDP 7844) 不通时固定走 http2（--protocol）。
//   · API 无鉴权、监听 0.0.0.0：仅限局域网可信环境用（家庭 NAS 威胁模型），
//     能力也仅限于起停隧道。端口可用 CF_TUNNEL_PORT 覆盖（缺省 3999）。
import { createServer } from 'node:http'
import { spawn } from 'node:child_process'
import { readFileSync, writeFileSync, existsSync, appendFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = process.env.OPENBOX_ROOT || join(dirname(fileURLToPath(import.meta.url)), '..', '..')
const DATA = join(ROOT, 'data')
const BIN = join(ROOT, 'bin', 'cloudflared')
const STATE_FILE = join(DATA, 'cf-tunnel.json')
const TUNNEL_LOG = join(DATA, 'cf-tunnel.log')
const PORT = Number(process.env.CF_TUNNEL_PORT || 3999)
const URL_RE = /https:\/\/[a-z0-9-]+\.trycloudflare\.com/i
const REGISTERED_RE = /Registered tunnel connection/i

const readPanelPort = () => {
  try {
    const v = readFileSync(join(DATA, 'panel-port'), 'utf8').trim()
    const n = Number(v)
    if (Number.isInteger(n) && n > 0 && n < 65536) return n
  } catch {}
  return 3036
}

const readState = () => {
  try { return JSON.parse(readFileSync(STATE_FILE, 'utf8')) } catch {}
  return { running: false, url: '', pid: 0, panelPort: readPanelPort(), mode: 'quick', token: '', hostname: '', startedAt: 0, error: '' }
}

const writeState = (s) => {
  try { writeFileSync(STATE_FILE, JSON.stringify(s)) } catch {}
}

let child = null // cloudflared 进程
let starting = null // 进行中的启动 Promise

const binaryOk = () => existsSync(BIN)

const alive = (pid) => {
  if (!pid) return false
  try { process.kill(pid, 0); return true } catch { return false }
}

const status = () => {
  const s = readState()
  const panelPort = readPanelPort()
  if (s.running && s.pid && !alive(s.pid)) {
    // 进程已退出但状态没更新（异常死亡）——纠正状态
    s.running = false
    s.url = ''
    s.error = s.error || '隧道进程已退出'
    writeState(s)
  }
  return {
    running: !!s.running,
    url: s.url || '',
    mode: s.mode || 'quick',
    hasToken: !!(s.token && s.token.length),
    hostname: s.hostname || '',
    pid: s.pid || 0,
    panelPort,
    stale: !!(s.running && s.panelPort && s.panelPort !== panelPort),
    binaryOk: binaryOk(),
    error: s.error || '',
    startedAt: s.startedAt || 0,
  }
}

const killProc = (pid) => {
  if (!pid) return
  try { process.kill(-pid, 'SIGTERM') } catch {}
  setTimeout(() => { try { process.kill(-pid, 'SIGKILL') } catch {} }, 3000).unref()
}

const stopTunnel = () => {
  const s = readState()
  if (child && child.pid) killProc(child.pid)
  else if (s.pid && alive(s.pid)) killProc(s.pid)
  child = null
  // token/hostname/mode 保留（重启不用重贴），运行态清空
  writeState({ running: false, url: '', pid: 0, panelPort: readPanelPort(), mode: s.mode || 'quick', token: s.token || '', hostname: s.hostname || '', startedAt: 0, error: '' })
  return status()
}

const readBody = (req) => new Promise((resolve) => {
  let data = ''
  req.on('data', (c) => { data += c; if (data.length > 65536) req.destroy() })
  req.on('end', () => { try { resolve(data ? JSON.parse(data) : {}) } catch { resolve({}) } })
  req.on('error', () => resolve({}))
})

const startTunnel = (opts = {}) => {
  if (starting) return starting
  const cur = status()
  if (cur.running) return Promise.resolve(cur)
  if (!cur.binaryOk) {
    const s = readState()
    s.error = 'cloudflared 二进制缺失（bin/cloudflared）'
    writeState(s)
    return Promise.resolve(status())
  }
  const prev = readState()
  const mode = opts.mode === 'named' ? 'named' : 'quick'
  const token = typeof opts.token === 'string' && opts.token.trim() ? opts.token.trim() : (prev.token || '')
  const hostname = typeof opts.hostname === 'string' && opts.hostname.trim() ? opts.hostname.trim() : (prev.hostname || '')
  if (mode === 'named' && !token) {
    const s = readState()
    s.mode = 'named'
    s.error = '命名隧道需要 Token（Cloudflare dashboard → 你的隧道 → 安装连接器 里复制）'
    writeState(s)
    return Promise.resolve(status())
  }
  const panelPort = readPanelPort()
  starting = new Promise((resolve) => {
    const args = mode === 'named'
      ? ['tunnel', 'run', '--token', token, '--no-autoupdate', '--protocol', 'http2']
      : ['tunnel', '--url', `http://127.0.0.1:${panelPort}`, '--no-autoupdate', '--protocol', 'http2']
    const s0 = readState()
    s0.running = false; s0.url = ''; s0.error = ''
    s0.mode = mode; s0.token = token; s0.hostname = hostname; s0.panelPort = panelPort
    writeState(s0)
    const c = spawn(BIN, args, { detached: true, stdio: ['ignore', 'pipe', 'pipe'] })
    child = c
    let url = ''
    let settled = false
    const onLine = (line) => {
      if (mode === 'quick') {
        if (url) return
        const m = line.match(URL_RE)
        if (m) {
          url = m[0]
          const s = readState()
          s.running = true; s.url = url; s.pid = c.pid; s.panelPort = panelPort
          s.mode = mode; s.startedAt = Date.now(); s.error = ''
          writeState(s)
          settled = true
          resolve(status())
        }
      } else if (!settled) {
        // 命名隧道：地址用户自定（dashboard 配的 Public Hostname），
        // 日志出现 Registered tunnel connection 即视为就绪
        if (REGISTERED_RE.test(line)) {
          const s = readState()
          s.running = true; s.pid = c.pid; s.panelPort = panelPort
          s.url = hostname ? `https://${hostname.replace(/^https?:\/\//, '')}` : ''
          s.mode = mode; s.startedAt = Date.now(); s.error = ''
          writeState(s)
          settled = true
          resolve(status())
        }
      }
    }
    c.stdout.on('data', (d) => d.toString().split('\n').forEach(onLine))
    c.stderr.on('data', (d) => {
      const text = d.toString()
      try { appendFileSync(TUNNEL_LOG, text) } catch {}
      text.split('\n').forEach(onLine)
    })
    c.on('exit', (code) => {
      if (!settled) {
        const s = readState()
        s.running = false; s.url = ''; s.pid = 0
        s.error = `cloudflared 退出（code=${code}），详见 data/cf-tunnel.log`
        if (mode === 'named') s.error += '；命名隧道请检查 Token 是否有效、dashboard 里是否已给该隧道配置 Public Hostname'
        writeState(s)
        settled = true
        resolve(status())
      } else {
        const s = readState()
        if (s.running && s.pid === c.pid) {
          s.running = false; s.url = ''; s.pid = 0
          s.error = `隧道进程退出（code=${code}）`
          writeState(s)
        }
      }
      child = null
    })
    // 45 秒拿不到就绪信号就判失败（命名隧道建连稍慢）
    setTimeout(() => {
      if (!settled) {
        settled = true
        killProc(c.pid)
        const s = readState()
        s.running = false; s.url = ''; s.pid = 0
        s.error = '启动超时（45s 未就绪），请检查 NAS 到 Cloudflare 的连通性' + (mode === 'named' ? '或 Token 是否有效' : '')
        writeState(s)
        resolve(status())
      }
    }, 45000).unref()
  }).finally(() => { starting = null })
  return starting
}

const json = (res, code, obj) => {
  const body = JSON.stringify(obj)
  res.writeHead(code, {
    'Content-Type': 'application/json; charset=utf-8',
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type',
    'Cache-Control': 'no-store',
  })
  res.end(body)
}

createServer((req, res) => {
  const u = new URL(req.url, 'http://127.0.0.1')
  if (req.method === 'OPTIONS') return json(res, 204, {})
  if (u.pathname === '/api/status' && req.method === 'GET') return json(res, 200, status())
  if (u.pathname === '/api/start' && req.method === 'POST') {
    return readBody(req).then((opts) => startTunnel(opts).then((s) => json(res, 200, s)))
  }
  if (u.pathname === '/api/stop' && req.method === 'POST') return json(res, 200, stopTunnel())
  return json(res, 404, { error: 'not found' })
}).listen(PORT, '0.0.0.0', () => {
  // 启动时纠正状态：supervise 重启过，旧 pid 已无效
  const s = readState()
  if (s.running && s.pid && !alive(s.pid)) {
    s.running = false; s.url = ''; s.pid = 0
    writeState(s)
  }
  console.log(`cf-tunnel helper listening on 0.0.0.0:${PORT} (root ${ROOT})`)
})

// 停应用（supervise 杀本进程）时连带停隧道：cloudflared 是脱离的进程组，
// 不杀会继续指向已经停掉的面板
const cleanup = () => {
  const s = readState()
  if (s.running && s.pid && alive(s.pid)) killProc(s.pid)
  process.exit(0)
}
process.on('SIGTERM', cleanup)
process.on('SIGINT', cleanup)
