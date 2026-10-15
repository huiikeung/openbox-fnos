#!/bin/bash
# ============================================================================
# Open-Box fnOS fpk 打包脚本
# 用法: ./scripts/build_fpk.sh [版本号] [arch...]
#   ./scripts/build_fpk.sh                 # 按 manifest 版本构建 x64 + arm64
#   ./scripts/build_fpk.sh 0.1.303 x64     # 只构建 x64
#
# 产物（dist/）：
#   fnnas.openbox-<版本>-x64.fpk     x86_64（sing-box + glibc Node 均为 x64）
#   fnnas.openbox-<版本>-arm64.fpk   aarch64
#
# 构建流程（每个架构）：
#   1. 下载 Open-Box 官方发布包 open-box-linux-<arch>.tar.gz 并校验 SHA256
#      （发布包 = sing-box 魔改内核 + Node 运行时 + 面板 + GeoSite/GeoIP）
#   2. 用 nodejs.org 官方 glibc 版 Node 替换包内 musl 版（与上游 Debian
#      安装脚本 openbox_glibc_node 同做法，校验 SHASUMS256.txt）
#   3. 打 fnOS 补丁：
#      · debian/bin/ 换成 fnOS 版服务脚本（openbox-ctl / openbox-panel-ctl /
#        openbox-panel-run / openbox-supervise，不走 systemd）
#      · openwrt/bin/open-box 的 ROOT 改为可重定位（OPENBOX_ROOT / 自定位）
#      · update.sh / uninstall.sh 换成占位 stub（升级走 fnOS 应用中心）
#      · conflicts.mjs 增加 fnSoar(Mihomo) 冲突检测条目，并 node --check 校验
#      · 删除 OpenWrt 专有目录（luci / initd）与面板测试目录
#   4. 按 fnpack 规范组装 stage（manifest / cmd / config / wizard / ui /
#      图标 + app/ 载荷）并 fnpack build 成 fpk
#
# 仓库布局：
#   fnpack/       fnOS 打包源（manifest/cmd/config/wizard/ui + app 覆盖脚本）
#   resources/    第三方资产（发布包 / Node 下载缓存，不入库）
#   scripts/      构建脚本
#   dist/         构建产物
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FNPACK_DIR="${PROJECT_ROOT}/fnpack"
DL_DIR="${PROJECT_ROOT}/resources/downloads"
NODE_CACHE="${PROJECT_ROOT}/resources/node"
BUILD_DIR="${PROJECT_ROOT}/dist/tmp_build"
OUT_DIR="${PROJECT_ROOT}/dist"

MANIFEST_VERSION="$(sed -n 's/^version[[:space:]]*=[[:space:]]*//p' "${FNPACK_DIR}/manifest" | head -n1 | tr -d '[:space:]')"
VERSION="${1:-${MANIFEST_VERSION}}"
shift || true
ARCHES=("$@")
if [ "${#ARCHES[@]}" -eq 0 ]; then
    ARCHES=(x64 arm64)
fi

APPNAME="$(sed -n 's/^appname[[:space:]]*=[[:space:]]*//p' "${FNPACK_DIR}/manifest" | head -n1 | tr -d '[:space:]')"
if [ -z "${APPNAME}" ]; then
    echo "错误: 无法从 manifest 解析 appname" >&2
    exit 1
fi

# 上游发布仓库与内置镜像（与 Open-Box install.sh 保持一致）
REPO="liandu2024/Open-Box"
PIN_TAG="${OPENBOX_TAG:-v0.1.306}"
MIRRORS="https://ghfast.top https://gh-proxy.com https://gh.llkk.cc"

# Cloudflare 快捷隧道二进制（fnOS 本地功能：「后端设置」页的「Cloudflare 隧道」卡片）。
# 版本与 SHA256 来自 cloudflare/cloudflared GitHub release digest，升级时同步改。
CF_VER="2026.10.0"
CF_CACHE="${PROJECT_ROOT}/resources/cloudflared"
cf_asset_of() { case "$1" in x64) echo "cloudflared-linux-amd64";; arm64) echo "cloudflared-linux-arm64";; esac; }
cf_sha_of() {
    case "$1" in
        x64)   echo "d33ff2d14475178d2012c2c56beba87389ac5ded27649519f198a7d3134a99db";;
        arm64) echo "e6422b9d4f72d3194bc5a38676f13667c06666523217b842a877d72a80b5ac08";;
    esac
}

mkdir -p "${DL_DIR}" "${NODE_CACHE}" "${CF_CACHE}" "${BUILD_DIR}" "${OUT_DIR}"

# ── 下载辅助：直连失败依次尝试镜像 ─────────────────────────────────────────
gh_url() { printf 'https://github.com/%s/releases/download/%s/%s\n' "$REPO" "$PIN_TAG" "$1"; }

fetch_url() { # $1=url $2=out —— 直连 → 镜像
    local url="$1" out="$2" m
    if curl -fsSL --connect-timeout 12 --speed-limit 1024 --speed-time 60 -o "$out" "$url" 2>/dev/null; then
        return 0
    fi
    for m in $MIRRORS; do
        echo "    ⚠ 直连失败，尝试镜像 $m" >&2
        if curl -fsSL --connect-timeout 12 --max-time 600 -o "$out" "$m/$url" 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

sha_ok() { # $1=file $2=expected
    [ -f "$1" ] || return 1
    local got
    got="$(sha256sum "$1" | awk '{print $1}')"
    [ "$got" = "$2" ]
}

# ── 架构映射 ───────────────────────────────────────────────────────────────
node_arch_of() { case "$1" in x64) echo x64 ;; arm64) echo arm64 ;; esac; }
fnos_platform_of() { case "$1" in x64) echo x86 ;; arm64) echo arm ;; esac; }

build_arch() {
    local arch="$1"
    # 缓存文件名带 tag：换 PIN_TAG 必须重新下载，不复用旧包
    local ob_asset="open-box-${PIN_TAG}-linux-${arch}.tar.gz"
    local stage="${BUILD_DIR}/stage-${arch}"
    local app="${stage}/app"

    echo ""
    echo "=== 构建 ${APPNAME} ${VERSION} (${arch}) ==="

    # 1. Open-Box 发布包 ────────────────────────────────────────────────────
    local tarball="${DL_DIR}/${ob_asset}"
    local shafile="${DL_DIR}/${ob_asset}.sha256"
    if [ ! -f "$tarball" ]; then
        echo "[1/6] 下载 ${ob_asset} ..."
        fetch_url "$(gh_url "$ob_asset")" "$tarball" || { echo "错误: 下载 ${ob_asset} 失败" >&2; exit 1; }
        fetch_url "$(gh_url "${ob_asset}.sha256")" "$shafile" || { echo "错误: 下载 SHA256 失败" >&2; exit 1; }
    else
        echo "[1/6] 复用已下载的 ${ob_asset}"
        [ -f "$shafile" ] || fetch_url "$(gh_url "${ob_asset}.sha256")" "$shafile" || true
    fi
    if [ -f "$shafile" ]; then
        local want
        want="$(awk 'NR==1{print $1}' "$shafile")"
        sha_ok "$tarball" "$want" || { echo "错误: ${ob_asset} SHA256 校验失败" >&2; exit 1; }
        echo "    ✓ SHA256 校验通过"
    else
        echo "    ⚠ 未取到 .sha256，跳过校验" >&2
    fi

    # 2. 解包 + glibc Node ──────────────────────────────────────────────────
    echo "[2/6] 解包并替换 glibc Node 运行时 ..."
    rm -rf "$stage"
    mkdir -p "$app"
    tar -xzf "$tarball" -C "$app"

    local node_ver node_arch node_txz node_dir
    node_ver="$(sed -n 's/.*"nodeVersion" *: *"\([^"]*\)".*/\1/p' "$app/meta.json" | head -n1)"
    node_arch="$(node_arch_of "$arch")"
    if [ -z "$node_ver" ]; then
        echo "错误: meta.json 中缺少 nodeVersion" >&2
        exit 1
    fi
    node_txz="node-v${node_ver}-linux-${node_arch}.tar.xz"
    node_dir="${NODE_CACHE}/node-v${node_ver}-linux-${node_arch}"

    if [ ! -x "${node_dir}/bin/node" ]; then
        echo "    ↓ 下载 ${node_txz} (nodejs.org) ..."
        local tmp_node="${NODE_CACHE}/${node_txz}"
        if ! curl -fsSL --connect-timeout 12 --max-time 600 -o "$tmp_node" \
            "https://nodejs.org/dist/v${node_ver}/${node_txz}" 2>/dev/null; then
            echo "    ⚠ nodejs.org 失败，尝试 npmmirror ..." >&2
            curl -fsSL --connect-timeout 12 --max-time 600 -o "$tmp_node" \
                "https://npmmirror.com/mirrors/node/v${node_ver}/${node_txz}" || { echo "错误: Node 下载失败" >&2; exit 1; }
        fi
        # 校验 SHASUMS256.txt
        curl -fsSL --connect-timeout 12 --max-time 120 \
            -o "${NODE_CACHE}/SHASUMS256.txt" \
            "https://nodejs.org/dist/v${node_ver}/SHASUMS256.txt" 2>/dev/null || true
        if [ -f "${NODE_CACHE}/SHASUMS256.txt" ]; then
            local want have
            want="$(grep " ${node_txz}\$" "${NODE_CACHE}/SHASUMS256.txt" | awk '{print $1}' | head -n1)"
            have="$(sha256sum "$tmp_node" | awk '{print $1}')"
            [ -n "$want" ] && [ "$want" = "$have" ] || { echo "错误: Node SHA256 校验失败" >&2; exit 1; }
            echo "    ✓ Node SHA256 校验通过"
        fi
        rm -rf "$node_dir"
        mkdir -p "$node_dir"
        tar -xJf "$tmp_node" -C "$node_dir" --strip-components=1 "${node_txz%.tar.xz}/bin/node" 2>/dev/null \
            || tar -xJf "$tmp_node" -C "$node_dir" --strip-components=1 || true
        # 有些 tar 实现 --strip-components 对单文件提取行为不同，兜底整包解压
        if [ ! -x "${node_dir}/bin/node" ]; then
            local full="${NODE_CACHE}/full-${node_txz%.tar.xz}"
            rm -rf "$full"; mkdir -p "$full"
            tar -xJf "$tmp_node" -C "$full"
            mv "$full/${node_txz%.tar.xz}/bin/node" "${node_dir}/bin/node" 2>/dev/null || true
            rm -rf "$full"
        fi
        [ -x "${node_dir}/bin/node" ] || { echo "错误: 未能从 Node 包中取得 bin/node" >&2; exit 1; }
        rm -f "$tmp_node"
    else
        echo "    ✓ 复用 Node ${node_ver} (${node_arch})"
    fi

    # 替换 musl Node：只留 glibc bin/node，删掉 musl 的 node/lib（与上游
    # Debian 安装脚本一致：glibc Node 加载 musl 版 libstdc++ 会崩）
    mkdir -p "$app/node/bin"
    cp -f "${node_dir}/bin/node" "$app/node/bin/node"
    chmod 755 "$app/node/bin/node"
    rm -rf "$app/node/lib"
    printf 'glibc %s\n' "$node_ver" > "$app/node/.flavor"
    echo "    ✓ Node ${node_ver} glibc (${node_arch}) 就绪"

    # 2b. cloudflared（Cloudflare 快捷隧道助手运行时，随架构；SHA256 校验）────
    local cf_asset cf_out cf_want
    cf_asset="$(cf_asset_of "$arch")"
    cf_out="${CF_CACHE}/cloudflared-${CF_VER}-${cf_asset}"
    cf_want="$(cf_sha_of "$arch")"
    if [ -z "$cf_want" ]; then
        echo "错误: 未知架构 ${arch} 的 cloudflared SHA256" >&2
        exit 1
    fi
    if ! sha_ok "$cf_out" "$cf_want"; then
        echo "    ↓ 下载 ${cf_asset} (cloudflared ${CF_VER}) ..."
        if ! fetch_url "https://github.com/cloudflare/cloudflared/releases/download/${CF_VER}/${cf_asset}" "$cf_out"; then
            echo "错误: 下载 ${cf_asset} 失败" >&2
            exit 1
        fi
        sha_ok "$cf_out" "$cf_want" || { echo "错误: ${cf_asset} SHA256 校验失败" >&2; exit 1; }
    else
        echo "    ✓ 复用 cloudflared ${CF_VER} (${cf_asset})"
    fi
    mkdir -p "$app/bin"
    cp -f "$cf_out" "$app/bin/cloudflared"
    chmod 755 "$app/bin/cloudflared"
    echo "    ✓ cloudflared ${CF_VER} (${arch}) 就绪"

    # 3. fnOS 补丁 ─────────────────────────────────────────────────────────
    echo "[3/6] 应用 fnOS 补丁 ..."

    # 3a. 删除 OpenWrt 专有目录与测试目录
    rm -rf "$app/openwrt/luci" "$app/openwrt/initd" "$app/panel/server/test"

    # 3b. 服务脚本与 stub 覆盖
    # debian/bin 整个目录覆盖（ctl / panel-ctl / panel-run / supervise /
    # gateway / gateway.mjs …），新增文件无需改这里
    cp -f "${FNPACK_DIR}/app/debian/bin/"* "$app/debian/bin/"
    cp -f "${FNPACK_DIR}/app/update.sh"                       "$app/update.sh"
    cp -f "${FNPACK_DIR}/app/uninstall.sh"                    "$app/uninstall.sh"
    chmod 755 "$app/debian/bin/"* "$app/update.sh" "$app/uninstall.sh" 2>/dev/null || true

    # 3c. open-box CLI：ROOT 可重定位（v0.1.326 起上游已原生支持自定位，无需再补）
    python3 - "$app/openwrt/bin/open-box" <<'PYEOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
s = p.read_text(encoding='utf-8')
if 'ROOT="${OPENBOX_ROOT:-' in s:
    print('    ✓ open-box CLI 已原生支持可重定位 ROOT（跳过）')
    sys.exit(0)
s = s.replace(
    'ROOT=/opt/open-box',
    'ROOT="${OPENBOX_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"', 1)
s = s.replace(
    'OPENBOX_PORT_FILE=/opt/open-box/data/panel-port',
    'OPENBOX_PORT_FILE="$ROOT/data/panel-port"', 1)
p.write_text(s, encoding='utf-8')
leftover = [l for l in s.splitlines() if '/opt/open-box' in l and not l.lstrip().startswith('#')]
if leftover:
    print('    ⚠ open-box CLI 仍残留 /opt/open-box 引用:', file=sys.stderr)
    for l in leftover:
        print('      ' + l.strip(), file=sys.stderr)
PYEOF

    # 3d. conflicts.mjs：增加 fnSoar(Mihomo) 冲突检测（fnOS 上最常见的冲突源）。
    #   v0.1.326 起面板服务端打成 minified bundle（system/conflicts.mjs 不存在），
    #   该补丁随之跳过——冲突检测逻辑改由上游 bundle 提供。
    python3 - "$app/panel/server/system/conflicts.mjs" <<'PYEOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
if not p.exists():
    print('    ⚠ system/conflicts.mjs 不存在（新版打包结构），跳过 fnSoar 冲突补丁', file=sys.stderr)
    sys.exit(0)
s = p.read_text(encoding='utf-8')
anchor = "  { id: 'homeproxy'"
entry = ("  { id: 'fnsoar', label: 'fnSoar (Mihomo)', "
         "initd: '/vol1/@appdata/fnnas.fnsoar', "
         "process: /mihomo-(?:amd64|arm64)/ },\n")
if 'fnsoar' not in s and anchor in s:
    s = s.replace(anchor, entry + anchor, 1)
    p.write_text(s, encoding='utf-8')
    print('    ✓ conflicts.mjs 增加 fnSoar 检测')
elif 'fnsoar' in s:
    print('    ✓ conflicts.mjs 已包含 fnSoar 检测')
else:
    print('    ⚠ 未找到 homeproxy 锚点，跳过 fnSoar 冲突补丁', file=sys.stderr)
PYEOF

    # 3d-1b.（v0.1.326 起改方案，v0.1.319 再加强）Cloudflare 隧道卡片的 API 转发：
    #   上游把 panel/server 打成带完整性清单(hardening-manifest.json)的 minified
    #   bundle，index.mjs 找不到注入锚点且改它会触发 Go 核心校验失败。两层方案：
    #   ① 网关层：openbox-gateway.mjs 把 /api/fnoscf/* 重写成 /api/* 转发到助手
    #      (:3999)——覆盖走网关 socket 的路径（应用中心 iframe 的静态/WS 等）；
    #   ② 前置代理层（v0.1.319 新增，关键）：实测 fnOS 应用中心(:5667)与 FN Connect
    #      (fnos.net)对 /api/* 的请求直达面板服务端口、不过网关 socket，所以面板
    #      进程退到内网端口 3037，由 openbox-front.mjs 守对外端口(panel-port)：
    #      /api/fnoscf/* → 助手，其余 → 内层面板。卡片走同源相对路径 api/fnoscf/...，
    #      三种打开方式（局域网 IP / 应用中心 / fnos.net）全部有入口；旧版面板无
    #      这些路由时 JS 自动退回直连助手(同 HTTP 无混合内容问题)。

    # 3d-1c. 订阅分享 host 字段清洗：容忍用户粘贴完整 URL。
    #   分享链接按 `协议://host/sub/token` 拼接，host 里带 https:// 会拼出
    #   https://https://... 导致客户端「无法识别分享链接」。这里在规范化时
    #   剥掉协议前缀和末尾斜杠（域名/IP、域名:端口 原样保留）。
    python3 - "$app/panel/server/api/subscription-shares.mjs" <<'PYEOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
if not p.exists():
    print('    ⚠ api/subscription-shares.mjs 不存在（新版打包结构），跳过 host 清洗补丁', file=sys.stderr)
    sys.exit(0)
s = p.read_text(encoding='utf-8')
MARK = 'fnos-openbox: share host clean'
if MARK in s:
    print('    ✓ subscription-shares.mjs 已包含 host 清洗（跳过）')
    sys.exit(0)
def_anchor = 'const normalizeRecord = (raw) => ({'
helper = """/* fnos-openbox: share host clean — 容忍粘贴完整 URL：剥协议前缀与末尾斜杠 */
const cleanHost = (v) => String(v).trim().replace(/^[a-zA-Z][a-zA-Z0-9+.-]*:\\/\\//, '').replace(/\\/+$/, '')

"""
pairs = [
    ("host: typeof raw?.host === 'string' ? raw.host.trim() : '',",
     "host: typeof raw?.host === 'string' ? cleanHost(raw.host) : '',"),
    ("const host = typeof req.body?.host === 'string' ? req.body.host.trim() : ''",
     "const host = typeof req.body?.host === 'string' ? cleanHost(req.body.host) : ''"),
    ("const host = req.body?.host === undefined ? current.host : (typeof req.body.host === 'string' ? req.body.host.trim() : '')",
     "const host = req.body?.host === undefined ? current.host : (typeof req.body.host === 'string' ? cleanHost(req.body.host) : '')"),
]
if def_anchor not in s:
    print('    ⚠ 未找到 subscription-shares.mjs 锚点，跳过 host 清洗', file=sys.stderr)
    sys.exit(0)
s = s.replace(def_anchor, helper + def_anchor, 1)
n = 0
for old, new in pairs:
    if old in s:
        s = s.replace(old, new, 1)
        n += 1
p.write_text(s, encoding='utf-8')
print(f'    ✓ subscription-shares.mjs host 清洗已注入（{n}/3 处替换）')
PYEOF

    # 3d-2. 前端补丁：移除概览页顶部推广横幅（安格超市 / SUPERDOOR / OPENDOOR）。
    #   做法：往 index.html 注入一段运行时脚本，**不碰 minified bundle**。
    #   （曾经按组件改写 chunk：node --check 只按 CommonJS 解析，抓不到 ESM strict
    #   模式下的语法问题，补丁让 chunk 解析失败、整个面板白屏——已弃用。）
    #   index.html 被面板下发 no-store（永远最新），因此无论浏览器手里是哪份
    #   immutable chunk 缓存都生效，也不依赖上游 bundle 的锚点。
    #   脚本逻辑：DOM 里出现指向 angeworld/superdoor/opendoor 的链接时，把其最近
    #   一级 .ctrls-bar 容器（即推广栏；其他工具栏不含这些链接）整体移除；
    #   初始跑一遍 + MutationObserver 盯着后续异步渲染/路由切换。
    #   同时注入一条 <style>：
    #   · img.app-logo 加 0.75rem 左边距，使侧栏 logo 与下方菜单图标的左边缘对齐
    #     （daisyUI 菜单项有 12px 内边距）；
    #   · .sidebar .menu>li+li 加 0.5rem 上外边距：上游侧栏菜单项是 36px 高全圆角
    #     pill（radius 19.5px），项与项 0 间距紧贴，用户观感就是「卡片挨在一起」。
    #     补 0.5rem（与面板其他卡片/分区的 gap-2、--app-space 一致）使其分离；
    #     折叠态（w-13 纯图标）同样生效。作用域限定 .sidebar 内，不动页面里的
    #     其他 .menu（如设置页横向 settings-menu）。
    #     另注入第二段脚本（MARK2 = fnos-openbox: cf-tunnel ui）：在「设置 → 后端
    #     设置」页「导出与导入」模块上方插一张 Cloudflare 隧道卡片（起/停 quick tunnel、显示并复制
    #     trycloudflare.com 地址），数据来自本机助手 openbox-cf-tunnel.mjs（debian/bin，
    #     由 supervise 常驻，API 在 3999 端口）。隧道只覆盖面板与订阅分享的 HTTP，
    #     Shadowsocks 端口不过 Cloudflare——卡片文案里写明了。两段脚本各自幂等。
    python3 - "$app/panel/dist/index.html" <<'PYEOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
html = p.read_text(encoding='utf-8')
CF_UI = '''<script>
/* fnos-openbox: cf-tunnel ui — 「后端设置」页的 Cloudflare 隧道卡片 */
/* 数据来自本机助手 openbox-cf-tunnel.mjs（默认 3999 端口）。两种模式：
   快捷隧道（无需账户，随机 trycloudflare.com 地址，重启即变）；
   命名隧道（CF 账户+域名，dashboard 建隧道拿 token，地址固定）。
   隧道只覆盖面板与订阅分享的 HTTP 流量，Shadowsocks 端口不过 Cloudflare。
   API 走面板同源相对路径 api/fnoscf/...（服务端代理到助手，HTTPS 页面不受
   混合内容限制）；旧版本面板没有该代理时退回直连 http://<主机名>:3999。 */
(function(){
  if (window.__fnosCfTunnel) return; window.__fnosCfTunnel = true;
  var CARD_ID = 'fnos-cf-tunnel-card';
  var DIRECT_API = 'http://' + location.hostname + ':3999';
  var useDirect = false;
  var timer = null;

  function el(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != null) e.textContent = text;
    return e;
  }

  // 统一 API 调用：同源代理优先，404/网络失败后退直连
  function callApi(action, method, body) {
    var base = useDirect ? (DIRECT_API + '/api/') : 'api/fnoscf/';
    var opts = { method: method || 'GET', credentials: useDirect ? 'omit' : 'same-origin' };
    if (body) { opts.headers = { 'Content-Type': 'application/json' }; opts.body = JSON.stringify(body); }
    return fetch(base + action, opts).then(function(r){
      if (!useDirect && (r.status === 404 || r.status === 405)) { useDirect = true; return callApi(action, method, body); }
      return r.json();
    }).catch(function(e){
      if (!useDirect) { useDirect = true; return callApi(action, method, body); }
      throw e;
    });
  }

  function findSharePage() {
    // 锚点：设置页的横向菜单 .settings-menu（空态/有服务器态都存在）
    var menu = document.querySelector('.settings-menu');
    if (!menu) return null;
    var active = menu.querySelector('.menu-active');
    if (!active || !/后端设置|Backend/i.test(active.textContent || '')) return null;
    var root = menu.parentElement;
    if (!root) return null;
    // 设置页根下的页面内容容器：div.flex.flex-col.gap-2.px-2（文档序里它是祖先，排最前）
    var cands = root.querySelectorAll('div.flex.flex-col.gap-2');
    for (var i = 0; i < cands.length; i++) {
      var c = cands[i];
      if (c !== root && /px-2/.test((c.className || '').toString())) return c;
    }
    return null;
  }

  function buildCard() {
    var card = el('div', 'card bg-base-100 p-4 flex flex-col gap-3');
    card.id = CARD_ID;
    var head = el('div', 'flex items-center justify-between gap-2');
    head.appendChild(el('div', 'font-semibold text-sm', 'Cloudflare 隧道'));
    var badge = el('span', 'badge badge-sm badge-neutral', '检测中');
    badge.id = 'cf-badge';
    head.appendChild(badge);
    card.appendChild(head);
    card.appendChild(el('div', 'text-xs opacity-70 leading-relaxed',
      '把面板暴露到外网（仅 HTTP）：浏览器远程打开面板、以及「共享网络」页里订阅分享的 Domain or IP 都能用它。注意隧道地址≠分享链接——订阅分享两步：①点「复制主机名」→ ②填到「共享网络」页订阅分享的 Domain or IP，面板会生成 https://主机名/sub/令牌 的真正分享链接。Shadowsocks 端口不过 Cloudflare，手机代理仍走局域网或路由器转发。快捷隧道地址生成后边缘注册要一会儿（实测 30 秒到 2 分钟不等），打不开就等等再试。'));
    // 模式切换
    var modeRow = el('div', 'flex items-center gap-2 text-xs');
    modeRow.appendChild(el('span', 'opacity-70', '模式'));
    var mk = function(id, label, title) {
      var b = el('button', 'btn btn-xs', label);
      b.id = id; b.type = 'button'; b.title = title || '';
      return b;
    };
    var mQuick = mk('cf-mode-quick', '快捷隧道', '无需账户，随机 trycloudflare.com 地址，重启即变');
    var mNamed = mk('cf-mode-named', '命名隧道', 'Cloudflare 账户+域名，dashboard 建隧道拿 token，地址固定');
    modeRow.appendChild(mQuick); modeRow.appendChild(mNamed);
    card.appendChild(modeRow);
    // 命名隧道参数（默认隐藏）
    var namedBox = el('div', 'flex-col gap-2 hidden');
    namedBox.id = 'cf-named-box';
    var tok = el('input', 'input input-bordered input-sm w-full');
    tok.id = 'cf-token'; tok.type = 'password'; tok.placeholder = '隧道 Token（dashboard → 安装连接器 里复制）';
    tok.autocomplete = 'new-password';
    namedBox.appendChild(tok);
    var host = el('input', 'input input-bordered input-sm w-full');
    host.id = 'cf-hostname'; host.placeholder = '对外域名（dashboard 里给隧道配的 Public Hostname，如 box.example.com）';
    namedBox.appendChild(host);
    card.appendChild(namedBox);
    // 地址行
    var urlRow = el('div', 'flex items-center gap-2');
    var url = el('input', 'input input-bordered input-sm flex-1 min-w-0');
    url.id = 'cf-url'; url.readOnly = true; url.placeholder = '未运行';
    urlRow.appendChild(url);
    var copy = el('button', 'btn btn-sm', '复制');
    copy.id = 'cf-copy';
    urlRow.appendChild(copy);
    var copyHost = el('button', 'btn btn-sm', '复制主机名');
    copyHost.id = 'cf-copy-host';
    copyHost.title = '复制不带 https:// 的主机名——填到「共享网络」页订阅分享的 Domain or IP 用（面板会据此生成真正的分享链接）';
    urlRow.appendChild(copyHost);
    card.appendChild(urlRow);
    // 操作行
    var btnRow = el('div', 'flex items-center gap-2');
    var start = el('button', 'btn btn-primary btn-sm', '启动隧道');
    start.id = 'cf-start';
    var stop = el('button', 'btn btn-sm', '停止');
    stop.id = 'cf-stop'; stop.disabled = true;
    btnRow.appendChild(start); btnRow.appendChild(stop);
    card.appendChild(btnRow);
    var err = el('div', 'text-xs text-error hidden leading-relaxed');
    err.id = 'cf-err';
    card.appendChild(err);
    // 事件
    var mode = 'quick';
    var setMode = function(m) {
      mode = m;
      mQuick.className = 'btn btn-xs' + (m === 'quick' ? ' btn-active' : ' btn-ghost');
      mNamed.className = 'btn btn-xs' + (m === 'named' ? ' btn-active' : ' btn-ghost');
      namedBox.className = m === 'named' ? 'flex flex-col gap-2' : 'hidden';
      url.placeholder = m === 'named' ? '未运行（用你的对外域名访问）' : '未运行';
    };
    mQuick.onclick = function(){ setMode('quick'); };
    mNamed.onclick = function(){ setMode('named'); };
    setMode('quick');
    start.onclick = function(){
      var body = { mode: mode };
      if (mode === 'named') {
        var t = document.getElementById('cf-token').value.trim();
        var h = document.getElementById('cf-hostname').value.trim();
        if (t) body.token = t;
        if (h) body.hostname = h;
      }
      api('start', body);
    };
    stop.onclick = function(){ api('stop'); };
    copy.onclick = function(){
      var u = document.getElementById('cf-url');
      if (u && u.value) {
        u.select(); u.setSelectionRange(0, 99999);
        try { document.execCommand('copy'); } catch(e) {}
        copy.textContent = '已复制';
        setTimeout(function(){ copy.textContent = '复制'; }, 1500);
      }
    };
    copyHost.onclick = function(){
      var u = document.getElementById('cf-url');
      if (u && u.value) {
        var hostOnly = u.value.replace(/^https?:\/\//, '').replace(/\/+$/, '');
        var tmp = document.createElement('textarea');
        tmp.value = hostOnly;
        document.body.appendChild(tmp);
        tmp.select();
        try { document.execCommand('copy'); } catch(e) {}
        document.body.removeChild(tmp);
        copyHost.textContent = '已复制';
        setTimeout(function(){ copyHost.textContent = '复制主机名'; }, 1500);
      }
    };
    return card;
  }

  function showErr(msg) {
    var err = document.getElementById('cf-err');
    if (err) { err.textContent = msg; err.classList.remove('hidden'); }
  }

  function api(action, body) {
    var badge = document.getElementById('cf-badge');
    if (badge) badge.textContent = action === 'start' ? '启动中…' : '停止中…';
    callApi(action, 'POST', body)
      .then(render)
      .catch(function(){
        if (badge) badge.textContent = '助手不可达';
        showErr('连不上隧道助手：请确认通过局域网 IP（http://<NAS IP>:3036）或 fnOS 应用中心打开面板，且应用正在运行。');
      });
  }

  function render(s) {
    if (!document.getElementById(CARD_ID)) return;
    var badge = document.getElementById('cf-badge');
    var url = document.getElementById('cf-url');
    var start = document.getElementById('cf-start');
    var stop = document.getElementById('cf-stop');
    if (!s || !s.binaryOk) {
      if (badge) badge.textContent = '二进制缺失';
      showErr('bin/cloudflared 缺失，请把应用更新到最新版。');
      return;
    }
    if (s.mode === 'named') setModeUI('named', s.hasToken, s.hostname);
    else setModeUI('quick', s.hasToken, s.hostname);
    if (s.running) {
      if (badge) badge.textContent = '运行中';
      if (url) url.value = s.url || '';
      if (start) start.disabled = true;
      if (stop) stop.disabled = false;
      var err0 = document.getElementById('cf-err');
      if (err0 && !s.stale) err0.classList.add('hidden');
      if (s.stale) showErr('注意：面板端口已变为 ' + s.panelPort + '，隧道仍指向旧端口，请停止后重新启动。');
    } else {
      if (badge) badge.textContent = '未运行';
      if (url) url.value = '';
      if (start) start.disabled = false;
      if (stop) stop.disabled = true;
      var err = document.getElementById('cf-err');
      if (s.error) { err.textContent = s.error; err.classList.remove('hidden'); }
      else err.classList.add('hidden');
    }
  }

  // 用状态里的模式回填 UI（含已保存 token 的占位提示）
  function setModeUI(mode, hasToken, hostname) {
    var mq = document.getElementById('cf-mode-quick');
    var mn = document.getElementById('cf-mode-named');
    var nb = document.getElementById('cf-named-box');
    var tok = document.getElementById('cf-token');
    var host = document.getElementById('cf-hostname');
    if (!mq || !mn || !nb) return;
    mq.className = 'btn btn-xs' + (mode === 'quick' ? ' btn-active' : ' btn-ghost');
    mn.className = 'btn btn-xs' + (mode === 'named' ? ' btn-active' : ' btn-ghost');
    nb.className = mode === 'named' ? 'flex flex-col gap-2' : 'hidden';
    if (tok && hasToken && !tok.value) tok.placeholder = '已保存（留空则不修改）';
    if (host && hostname && !host.value) host.value = hostname;
  }

  function poll() {
    if (!document.getElementById(CARD_ID)) { timer = null; return; }
    callApi('status')
      .then(render)
      .catch(function(){});
  }

  // 「导出与导入」模块（backupTitle）：卡片插在它上面，不抢页面最顶部
  function findBackupModule(page) {
    var kids = page.children;
    for (var i = 0; i < kids.length; i++) {
      var head = ((kids[i].innerText || '') + '').trim().slice(0, 30);
      if (/导出与导入/.test(head) || /^(Export|Backup|Import)/i.test(head)) return kids[i];
    }
    return null;
  }

  function ensure() {
    var page = findSharePage();
    if (!page) return;
    var existing = document.getElementById(CARD_ID);
    var anchor = findBackupModule(page);
    if (existing) {
      // 锚点可能比卡片晚渲染（SPA 流式渲染）：出现后把卡片挪到它正上方
      if (anchor && anchor.previousElementSibling !== existing) {
        page.insertBefore(existing, anchor);
      }
      if (!timer) { poll(); timer = setInterval(poll, 5000); }
      return;
    }
    var card = buildCard();
    if (anchor) page.insertBefore(card, anchor);
    else page.appendChild(card); // 锚点未出现：先落位，等后续 mutation 修正
    poll();
    if (!timer) timer = setInterval(poll, 5000);
  }

  if (window.MutationObserver) {
    new MutationObserver(function(){ ensure(); }).observe(document.documentElement, {childList: true, subtree: true});
  }
  ensure();
})();
</script>'''

MARK1 = 'fnos-openbox: promo-banner remover'
MARK2 = 'fnos-openbox: cf-tunnel ui'
injected = []
if MARK1 not in html:
     injected.append('''<script>
 /* fnos-openbox: promo-banner remover — 移除面板顶部推广(安格超市/SUPERDOOR/OPENDOOR) */
 (function(){
   var PROMO=/angeworld|superdoor|opendoor/i;
   function drop(a){
     var bar=a.closest?a.closest('.ctrls-bar'):null;
     (bar||a).remove();
   }
   function scan(root){
     if(!root||root.nodeType!==1)return;
     if(root.matches&&root.matches('a[href]')&&PROMO.test(root.getAttribute('href')||'')){drop(root);return;}
     var as=root.querySelectorAll?root.querySelectorAll('a[href]'):[];
     for(var i=0;i<as.length;i++)if(PROMO.test(as[i].getAttribute('href')||''))drop(as[i]);
   }
   scan(document.documentElement);
   if(window.MutationObserver){
     new MutationObserver(function(muts){
       for(var i=0;i<muts.length;i++){
         var added=muts[i].addedNodes;
         for(var j=0;j<added.length;j++)scan(added[j]);
       }
     }).observe(document.documentElement,{childList:true,subtree:true});
   }
 })();
 </script>''')
if MARK2 not in html:
     injected.append(CF_UI)
 # 对齐：daisyUI 菜单项有 12px(0.75rem) 内边距，菜单图标因此比 sidebar 左缘
 # 缩进 12px；给侧栏 logo 加同样左边距，使其与下方菜单图标左边缘对齐
 # （img.app-logo 只有 SidebarHeader 在用；侧栏折叠时 logo 不渲染，无副作用）。
style = '<style>img.app-logo{margin-left:.75rem}.sidebar .menu>li+li{margin-top:.5rem}</style>'
if '</head>' not in html:
     print('    ✗ index.html 缺少 </head>，无法注入', file=sys.stderr)
     sys.exit(1)
if injected or 'img.app-logo{margin-left:.75rem}' not in html:
     html = html.replace('</head>', ''.join(injected) + style + '</head>', 1)
     p.write_text(html, encoding='utf-8')
     print('    ✓ index.html 已注入去推广脚本 + logo 对齐样式 + 侧栏菜单间距 + Cloudflare 隧道 UI')
else:
     print('    ✓ index.html 已包含全部注入（跳过）')
PYEOF

    # 3d-4. 图标：以上游面板 PWA 图标（pwa-512x512.png）为源，烘焙圆角
    #   （squircle，r≈22.4%，4x 超采样抗锯齿），生成 fnOS 各尺寸图标。
    #   fnOS 不做服务端圆角遮罩，各应用图标自带圆角；直传上游方图会在应用中心
    #   里显得是直角。输出到构建目录，步骤 4 装进 stage。
    ICON_SRC="$app/panel/dist/pwa-512x512.png"
    ICON_OUT="${BUILD_DIR}/icons-${arch}"
    rm -rf "$ICON_OUT"
    mkdir -p "$ICON_OUT/ui/images"
    if [ ! -f "$ICON_SRC" ]; then
        echo "错误: 未找到图标源 $ICON_SRC" >&2
        exit 1
    fi
    python3 - "$ICON_SRC" "$ICON_OUT" <<'PYEOF'
import sys, pathlib
from PIL import Image, ImageDraw
src, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
img = Image.open(src).convert('RGBA')

def rounded(icon, size, ratio=0.2237, ss=4):
    big = size * ss
    mask = Image.new('L', (big, big), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, big - 1, big - 1], radius=int(big * ratio), fill=255)
    mask = mask.resize((size, size), Image.LANCZOS)
    canvas = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    canvas.paste(icon.resize((size, size), Image.LANCZOS), (0, 0), mask)
    return canvas

rounded(img, 512).save(out / 'ICON.PNG')
rounded(img, 256).save(out / 'ICON_256.PNG')
for s in (64, 128, 256, 512):
    rounded(img, s).save(out / 'ui' / 'images' / f'icon_{s}.png')
print('    ✓ 圆角图标已生成（512/256 + ui 64/128/256/512，r≈22.4%）')
PYEOF

    # 3d-5. SPA API 路径改相对（fnOS 同源网关兼容）：
    #   面板 fetch 用绝对路径 /api/...。经网关打开时页面地址是
    #   https://<nas>/app/fnnas.openbox/，绝对路径会绕过网关打到 fnOS 源站 →
    #   API 404、页面一直转圈。改成相对路径 api/... 后两种打开方式都通：
    #   直接访问 http://<ip>:3036/      → /api/...（同源，行为不变）
    #   网关访问 https://<nas>/app/...  → /app/fnnas.openbox/api/... → 网关
    #   路由是扁平的（/、/login、/setup + catchAll，无多级路径），相对解析安全；
    #   axios 的 baseURL（/api/controller）与 /rules/ 等调用路径会正确拼接。
    #   正则字面量里的转义形式 \/api\/ 一并处理（settings-saved 事件匹配用）。
    python3 - "$app/panel/dist/assets" <<'PYEOF'
import sys, pathlib
assets = pathlib.Path(sys.argv[1])
n = 0
for f in sorted(assets.glob('*.js')):
    s = orig = f.read_text(encoding='utf-8')
    s = s.replace('/api/', 'api/')
    s = s.replace('\\/api\\/', 'api\\/')
    if s != orig:
        f.write_text(s, encoding='utf-8')
        n += 1
if n == 0:
    print('    ✗ 没有 chunk 被改动（上游 bundle 结构变了？）', file=sys.stderr)
    sys.exit(1)
print(f'    ✓ {n} 个 chunk 的 API 路径已改为相对（api/...）')
PYEOF

    # 3e. 语法校验。node --check 与平台无关（纯 JS 语法），跨架构构建时用
    #     resources/node 里缓存的 x64 Node 作宿主；服务端入口、冲突补丁、
    #     前端 bundle 和 index.html 里注入的内联脚本都要过一遍。
    #     注意：bundle 是浏览器 ESM，node --check 按 CJS 解析会漏掉 strict 模式
    #     错误——内联脚本额外用 .mjs（ESM 模式）校验，双保险。
    HOST_NODE=""
    if "$app/node/bin/node" --version >/dev/null 2>&1; then
        HOST_NODE="$app/node/bin/node"
    else
        HOST_NODE="$(ls "${NODE_CACHE}"/node-v*-linux-x64/bin/node 2>/dev/null | head -n1)"
    fi
    if [ -n "$HOST_NODE" ] && [ -x "$HOST_NODE" ]; then
        "$HOST_NODE" --check "$app/panel/server/index.mjs"
        # v0.1.326 起 system/conflicts.mjs 被打包进 bundle，不存在则跳过
        [ -f "$app/panel/server/system/conflicts.mjs" ] && "$HOST_NODE" --check "$app/panel/server/system/conflicts.mjs"
        "$HOST_NODE" --check "$app/debian/bin/openbox-gateway.mjs"
        "$HOST_NODE" --check "$app/debian/bin/openbox-cf-tunnel.mjs"
        "$HOST_NODE" --check "$app/debian/bin/openbox-front.mjs"
        for _objs in "$app/panel/dist/assets/"index-*.js; do
            "$HOST_NODE" --check "$_objs"
        done
        # index.html 内联脚本（无 src 的 script 块）逐个按 ESM 校验
        python3 - "$app/panel/dist/index.html" "$HOST_NODE" <<'PYEOF'
import sys, re, pathlib, subprocess, tempfile
html = pathlib.Path(sys.argv[1]).read_text(encoding='utf-8')
node = sys.argv[2]
blocks = [b for b in re.findall(r'<script(?![^>]*\bsrc=)[^>]*>(.*?)</script>', html, re.S) if b.strip()]
bad = 0
for i, b in enumerate(blocks):
    with tempfile.NamedTemporaryFile('w', suffix='.mjs', delete=False) as f:
        f.write(b)
        path = f.name
    r = subprocess.run([node, '--check', path], capture_output=True, text=True)
    if r.returncode != 0:
        first = (r.stderr.splitlines()[1][:100] if len(r.stderr.splitlines()) > 1 else r.stderr[:100])
        print(f'    ✗ index.html 内联脚本 #{i} 语法错误: {first}', file=sys.stderr)
        bad += 1
if bad:
    sys.exit(1)
print(f'    ✓ index.html 内联脚本校验通过（{len(blocks)} 个，ESM 模式）')
PYEOF
        echo "    ✓ 语法校验通过（服务端 + 前端 bundle + 内联脚本）"
    else
        echo "    ⚠ 找不到可执行的宿主 Node，跳过语法校验" >&2
    fi
    local want_em=62
    [ "$arch" = "arm64" ] && want_em=183
    for _obbin in "$app/bin/sing-box" "$app/bin/cloudflared" "$app/node/bin/node"; do
        local got_em
        got_em="$(od -An -tu1 -j18 -N1 "$_obbin" 2>/dev/null | tr -d ' ')"
        if [ "$got_em" != "$want_em" ]; then
            echo "错误: $_obbin 不是 ${arch} 的 ELF（e_machine=${got_em}, 期望 ${want_em}）" >&2
            exit 1
        fi
    done
    echo "    ✓ ELF 架构校验通过（${arch}）"

    # 4. 组装 fpk stage ────────────────────────────────────────────────────
    echo "[4/6] 组装 fpk stage ..."
    mkdir -p "$stage"
    cp -f "${FNPACK_DIR}/manifest" "$stage/manifest"
    cp -a "${FNPACK_DIR}/cmd"    "$stage/cmd"
    cp -a "${FNPACK_DIR}/config" "$stage/config"
    cp -a "${FNPACK_DIR}/wizard" "$stage/wizard"
    # ui/ 目录结构来自 fnpack（config 等），图标用 3d-4 生成的圆角版
    mkdir -p "$stage/app/ui/images"
    cp -f "${FNPACK_DIR}/ui/config" "$stage/app/ui/config"
    if [ -d "${ICON_OUT}/ui/images" ]; then
        cp -f "${ICON_OUT}/ui/images/"*.png "$stage/app/ui/images/"
    fi
    # 顶层图标：3d-4 生成的圆角版（生成失败上面已硬失败）
    cp -f "${ICON_OUT}/ICON.PNG" "${ICON_OUT}/ICON_256.PNG" "$stage/"

    sed -i "s/^platform[[:space:]]*=.*/platform              = $(fnos_platform_of "$arch")/" "$stage/manifest"
    sed -i "s/^version[[:space:]]*=[[:space:]]*[0-9.]*/version               = ${VERSION}/" "$stage/manifest"
    chmod -R a+rX "$stage/app"

    # 5. fnpack build ──────────────────────────────────────────────────────
    echo "[5/6] fnpack build ..."
    local outfpk="${OUT_DIR}/${APPNAME}-${VERSION}-${arch}.fpk"
    rm -f "$outfpk"
    ( cd "${BUILD_DIR}/out-${arch}" 2>/dev/null || { mkdir -p "${BUILD_DIR}/out-${arch}"; cd "${BUILD_DIR}/out-${arch}"; }
      rm -f "${APPNAME}.fpk"
      fnpack build --directory "$stage" )
    mv -f "${BUILD_DIR}/out-${arch}/${APPNAME}.fpk" "$outfpk"

    # 6. 验证 ──────────────────────────────────────────────────────────────
    echo "[6/6] 验证 ..."
    local size
    size="$(ls -lh "$outfpk" | awk '{print $5}')"
    echo "    → ${outfpk} (${size})"
    echo "    → manifest platform/version:"
    tar xzOf "$outfpk" manifest 2>/dev/null | grep -E '^(platform|version)' | sed 's/^/      /'
    echo "    → 顶层条目: $(tar tzf "$outfpk" | grep -vE '/|app\.tgz' | tr '\n' ' ')"
    echo "    → 载荷关键文件:"
    tar xzOf "$outfpk" app.tgz 2>/dev/null | tar tz 2>/dev/null | grep -E \
        -e '^bin/sing-box$' -e '^bin/cloudflared$' -e '^node/bin/node$' -e '^node/\.flavor$' \
        -e '^debian/bin/openbox-(ctl|panel-ctl|panel-run|supervise|gateway|gateway\.mjs)$' \
        -e '^openwrt/bin/open-box$' -e '^panel/server/index.mjs$' \
        -e '^meta.json$' -e '^update.sh$' -e '^ui/config$' \
        | sed 's/^/      ✓ /' || echo "      ✗ app.tgz 内容检查失败"
    # node/update.sh 等不应出现
    if tar xzOf "$outfpk" app.tgz 2>/dev/null | tar tz 2>/dev/null | grep -q '^node/lib/'; then
        echo "      ✗ node/lib（musl 库）未被删除" >&2
    fi
    echo "    ✓ ${arch} 构建完成"
}

for arch in "${ARCHES[@]}"; do
    build_arch "$arch"
done

echo ""
echo "=== 全部构建完成 ==="
ls -lh "${OUT_DIR}"/${APPNAME}-${VERSION}-*.fpk | sed 's/^/  /'
