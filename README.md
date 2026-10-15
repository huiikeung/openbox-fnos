<div align="center">

# Open-Box for fnOS

**Open-Box（sing-box 内核 + Web 面板的一体化透明代理方案）的 fnOS 原生应用版**

基于 [liandu2024/Open-Box](https://github.com/liandu2024/Open-Box) 官方发布包打包，适配 fnOS 应用生命周期（`.fpk`），
订阅、节点组、链式代理、目标分流、DNS、TUN 等全部在面板内完成，浏览器打开即用。

</div>

## ✨ 这是什么

把上游面向 OpenWrt / Debian 的 Open-Box 路由器端打包成 fnOS 原生应用：

- **sing-box 魔改内核**（`1.14.1-openbox-tcp23`，随包，按架构 x64 / arm64）
- **Node 24 运行时**（glibc 官方构建，随包）
- **完整 GeoSite / GeoIP 数据**（随包，首次启动即用）
- **Web 管理面板**（默认端口 `3036`，首次访问设置管理密码）

内核服务不依赖 systemd：由 `debian/bin/openbox-ctl` 直管 sing-box 进程（含 nftables 表、策略路由、
IP 转发等系统层动作，与上游 Debian 版逐函数一致）；面板由 `openbox-supervise` 监管，作为 fnOS
应用服务的单行命令运行。

## 📦 安装

### 方式一：fnOS 应用中心（推荐）

1. 下载 `dist/fnnas.openbox-<版本>-x64.fpk`（x86_64）或 `-arm64.fpk`（aarch64）
2.  fnOS「应用中心」→「手动安装」→ 选择 fpk
3. 安装向导只需确认面板端口（默认 **3036**）
4. 安装完成后从应用中心打开，或浏览器访问 `http://<NAS IP>:3036`，**首次访问设置面板密码**

### 方式二：命令行（本机验证过）

```bash
appcenter-cli install-fpk /path/to/fnnas.openbox-0.1.321-x64.fpk
appcenter-cli start fnnas.openbox
appcenter-cli status fnnas.openbox
```

> **升级注意**：`appcenter-cli install-fpk` 对**已安装**的应用不会替换文件（只提示
> "is installed"）。升级路径是：`appcenter-cli uninstall fnnas.openbox`（默认保留
> `/vol1/@appdata/fnnas.openbox` 数据）→ 再 `install-fpk` 新包 → `start`。
> 内核停机期间局域网走直连；`core-autostart` 存在时重装后内核自动恢复。

## 🔧 构建

```bash
# 构建两个架构（缺省版本号取 fnpack/manifest）
./scripts/build_fpk.sh

# 指定版本 / 只构建一个架构 / 换上游版本
./scripts/build_fpk.sh 0.1.303 x64
OPENBOX_TAG=v0.1.331 ./scripts/build_fpk.sh 0.1.321
```

构建流程：下载上游发布包（SHA256 校验）→ 用 nodejs.org 官方 glibc Node 替换包内 musl 版
（校验 SHASUMS256.txt）→ 打 fnOS 补丁 → `fnpack build` 产出 `dist/*.fpk`。
第三方资产缓存在 `resources/`（不入库），GitHub 直连不通时自动依次尝试
ghfast.top / gh-proxy.com / gh.llkk.cc 镜像。

## 🗂 目录结构

```
openbox/
├── fnpack/                    # fnOS 打包源
│   ├── manifest               # 应用清单（appname=fnnas.openbox, service_port=3036）
│   ├── cmd/                   # fnOS 生命周期（安装/升级/卸载/启停）
│   │   ├── service-setup      # 单行 SERVICE_COMMAND + 数据目录 symlink 策略
│   │   └── ...
│   ├── config/                # privilege(root) / resource / openbox.sc(端口声明)
│   ├── wizard/install         # 安装向导（仅面板端口）
│   ├── ui/                    # fnOS 桌面入口（iframe → 3036，端口随动）
│   └── app/                   # 覆盖上游的脚本（构建时覆盖进发布包）
│       ├── debian/bin/        # openbox-ctl / openbox-panel-ctl / panel-run / supervise
│       │                      # / openbox-cf-tunnel.mjs（Cloudflare 隧道助手，API :3999）
│       ├── openwrt/bin/open-box   # CLI（ROOT 可重定位）
│       └── update.sh / uninstall.sh  # 占位 stub
├── scripts/build_fpk.sh       # 构建脚本
├── resources/                 # 第三方资产缓存（不入库）
└── dist/                      # 构建产物（不入库）
```

安装后的布局：

| 路径 | 内容 |
|---|---|
| `/var/apps/fnnas.openbox/target/` | 应用目录（bin/node/panel/debian/openwrt/meta.json，fpk 升级时整体替换） |
| `/vol1/@appdata/fnnas.openbox/data/` | 面板 sqlite（密码/订阅/设置）、规则集、panel-port、内核 PID、日志 |
| `/vol1/@appdata/fnnas.openbox/etc/` | 生成的 sing-box `config.json`、entry-bypass.nft、证书 |
| `/vol1/@appdata/fnnas.openbox/geodata/` | GeoIP/GeoSite .srs（随 fpk 更新） |

`target/data`、`target/etc`、`target/panel/server/resources/geodata` 是指向 appdata 的
symlink——**升级 fpk 不会动你的订阅、规则和面板密码**。

## 🖥 使用

| 功能 | 位置 |
|---|---|
| 面板 | `http://<NAS IP>:3036`（fnOS 桌面图标同址） |
| 首次使用 | 打开面板 → 设置管理密码 → 「订阅管理」导入订阅 |
| 启动内核 | 面板内「启动」（会完整部署：规则集 → 校验 → 落盘 → DNS 接管 → 防火墙 → 启动 → 验证） |
| 开机自启 | 面板内内核卡片「自启」开关（= 上游 systemd enable 语义） |
| SSH 命令行 | `/var/apps/fnnas.openbox/target/openwrt/bin/open-box`（`password` / `port` / `check` / `restart`） |

面板会用到的固定端口：`3036`（面板）、`9095`（内核 Clash API，本机）、`7853`（内核 DNS）、
`7854`（DNS 重写，本机）、`7891`（回环入站）、`53`（DNS 劫持模式，需系统无其他 DNS 服务）。

## ⚠️ 与上游的差异 / 已知限制

0. **已移除概览页顶部推广横幅**（安格超市 / SUPERDOOR / OPENDOOR）：构建时往
   `index.html` 注入一段运行时脚本——**不碰 minified bundle**。脚本在 DOM 里
   出现指向 angeworld/superdoor/opendoor 的链接时，把其最近一级 `.ctrls-bar`
   容器（推广栏；其他工具栏不含这些链接）整体移除，MutationObserver 覆盖异步
   渲染/路由切换。选这个方案因为：① 面板对 `index.html` 下发 `no-store`（永远
   最新），无论浏览器手里是哪份 immutable chunk 缓存都生效；② 不依赖上游
   bundle 的 minified 锚点；③ 曾按组件改写 chunk，`node --check` 的 CJS 模式
   抓不到 ESM strict 模式语法错误，导致 chunk 解析失败、整页白屏（v0.1.305 的
   教训），注入脚本本身按 ESM 模式做语法校验。
1. **图标圆角为构建时烘焙**：以上游面板 PWA 图标为源加 squircle 圆角（r≈22.4%，
   4x 超采样抗锯齿），生成 ICON.PNG / ICON_256.PNG 与 ui/images 各尺寸。fnOS
   不做服务端圆角遮罩，直传方图会在应用中心里显得是直角。
2. **侧栏 logo 与菜单图标左缘对齐**：daisyUI 菜单项有 12px 内边距，菜单图标比
   sidebar 左缘缩进 12px，而 logo 顶在左缘——注入 `img.app-logo{margin-left:
   .75rem}` 把 logo 左边缘拉到与下方菜单图标对齐（实测 delta=0；折叠时 logo 不
   渲染，无副作用）。logo 图片本身保持上游原样。
3. **fnOS 同源网关（应用中心打开方式）**：ui/config 声明 `gatewaySocket:
   openbox.sock` + `gatewayPrefix: /app/fnnas.openbox`，fnOS 把
   `https://<nas>/app/fnnas.openbox/` 转发到应用目录下的 Unix socket，由
   `debian/bin/openbox-gateway.mjs`（Node 代理，HTTP+WebSocket、剥前缀）转到
   本地面板。没有它，HTTPS 的 fnOS 页面嵌 `http://<ip>:3036` 会被浏览器判为
   混合内容拦截，应用中心打开后白屏。为此 SPA 的 API 路径已改为相对
   （`/api/...` → `api/...`，构建时统一替换）：直接访问 `http://<ip>:3036/`
   与网关访问两种方式都通（路由扁平，相对解析安全）。已知限制：面板的
   WebSocket 通道硬编码 `ws://127.0.0.1:9095`（内核 Clash API），经网关或
   远程访问时日志/流量实时通道不可用（直连本机浏览器不受影响）。
4. **面板内升级已禁用**：上游 `update.sh` 面向 `/opt/open-box` + systemd，与 fnOS 应用目录
   不兼容。升级请走 fnOS 应用中心（数据目录保留）；GeoSite/GeoIP 也随 fpk 更新。
   面板「检查更新」仍可查版本（走镜像），点击升级会提示走应用中心。
5. **卸载走 fnOS 应用中心**：`uninstall.sh` 为占位；卸载时可选保留 appdata（订阅/规则/密码）。
6. **与其他代理应用互斥**：面板内置冲突检测（已增加 fnSoar/Mihomo 识别）。本机若跑着
   fnsoar 等其他代理内核，Open-Box 会拒绝启动内核——需先在那边停掉。两个代理同时运行会
   互抢防火墙/DNS/路由。
7. **端口**：`53` 被其他 DNS 服务占用时，DNS 劫持模式不可用（面板「后端设置」可换模式）。
8. **「模拟 LAN 终端」（真实路由调试）** 依赖 veth/ip netns，fnOS 默认内核可用；不可用时
   面板会自动退回内核诊断。
9. **分发合规**：上游仓库只开源了安装/升级/卸载脚本，**面板与 sing-box 内核是 Release 里的
   闭源资产**（许可证随安装包提供）。本仓库的 fnOS 打包代码可自由使用；**再分发打完的 fpk
   或上架应用中心前，请先获得上游作者同意**。
10. **侧栏菜单项之间增加间距**（v0.1.315 起，本地改动）：上游侧栏菜单项是 36px 高、
    全圆角（radius 19.5px）的 pill，项与项 0 间距紧贴，观感拥挤。构建时注入
    `.sidebar .menu>li+li{margin-top:.5rem}`（与面板其他卡片/分区的 gap-2 一致）
    使各项分离；折叠态（w-13 纯图标）同样生效。作用域限定 `.sidebar` 内的 `.menu`，
    设置页等页面内的其他菜单（如横向 settings-menu）不受影响。
11. **Cloudflare 隧道**（v0.1.317 起，本地新增）：「设置 → 后端设置」页里「导出与导入」模块上方有
     一张 Cloudflare 隧道卡片，两种模式：**快捷隧道**（无需账户，随机
     trycloudflare.com 地址，重启即变）和**命名隧道**（CF 账户+域名，dashboard
     建隧道拿 Token，地址固定，适合订阅分享）。组成：随包 `bin/cloudflared`
     （2026.10.0，按架构，SHA256 校验）+ `debian/bin/openbox-cf-tunnel.mjs`
     （常驻助手，随 supervise 启停，API 监听 `0.0.0.0:3999`）+ index.html 注入的
     卡片 UI。卡片经**同源相对路径** `api/fnoscf/*` 调助手，转发分两层：
     ① **前置代理**（v0.1.319 起，主力）：面板进程只听内网端口 `3037`，
     `openbox-front.mjs` 守对外端口（`panel-port`），`/api/fnoscf/*` 重写成
     `/api/*` 转助手、其余转面板——覆盖局域网 IP、fnOS 应用中心(:5667)、
     fnos.net 域名三条路径（实测后两者的 `/api/*` 请求直达面板服务端口、
     不过网关 socket，纯网关方案覆盖不到，这是 v0.1.319 修复「连不上隧道助手」
     的原因）；② 网关层：`openbox-gateway.mjs` 也保留 fnoscf 分流并直连内网
     面板，应用中心路径不依赖前置代理存活。卡片在旧版面板（无这些路由）时
     自动退回直连助手（同 HTTP 无混合内容问题）。
     **用途仅限面板远程访问与订阅分享**（订阅分享的「Domain or IP」填隧道地址
     即可外网同步）——Cloudflare 隧道只代理 HTTP(S)，Shadowsocks 端口不过
     Cloudflare，手机代理仍需局域网直连或路由器端口转发。其他：本机到 CF 边缘
     QUIC(UDP 7844) 不通时已固定 `--protocol http2`；快捷隧道地址生成后最多约
     30 秒边缘注册生效；命名隧道 Token 存 appdata（与 SS 密码同信任级别）；
     停应用会连带停隧道。

12. **上游 v0.1.326 硬化版的结构变化与补丁调整**：这版起 `panel/server` 打成
     minified ESM bundle + `hardening-manifest.json`（Go 核心 `native/openbox-core`
     `校验 index.mjs / cli/deploy.mjs / system/* 等入口完整性），`api/` 与
     `system/conflicts.mjs` 等单文件全部消失。由此：① fnSoar 冲突检测补丁跳过
     （冲突检测逻辑本身仍在 bundle 内，仅失去 fnSoar 专条）；② 订阅分享 host
     自动清洗补丁跳过（请用卡片「复制主机名」按钮获取不带协议的主机名）；
     ③ Cloudflare 隧道 API 转发改走本机网关（见上条）。`open-box` CLI 这版起
     原生支持可重定位 ROOT，我们的重定位补丁自动跳过；`openbox-ctl` 补了
     `running` 动作（新版部署流程的内核在跑检查会调它）。

## 🛠 故障排查

```bash
# 应用状态 / 启停
appcenter-cli status fnnas.openbox
appcenter-cli start|stop fnnas.openbox

# 日志
tail -f /vol1/@appdata/fnnas.openbox/data/supervise.log   # 监管器 + 面板 stdout
tail -f /vol1/@appdata/fnnas.openbox/data/kernel.log      # sing-box 内核日志
cat   /vol1/@appdata/fnnas.openbox/openbox.log            # fnOS 安装/服务日志

# 内核紧急停止（恢复直连）：停掉内核服务即可，post-stop 会清理 nft 表/策略路由/转发
/var/apps/fnnas.openbox/target/debian/bin/openbox-ctl stop
```

## ✅ 真机验证记录（fnOS x86_64 / Debian 12）

- [x] `appcenter-cli install-fpk` 安装 → postinst 建好 data/etc/geodata symlink 与 panel-port
- [x] 应用 start → 面板 `http://<NAS>:3036` HTTP 200，首次访问进入密码设置流程
- [x] `openbox-panel-ctl status` → running；`openbox-ctl status` → inactive(rc=3)
- [x] 面板进程被杀后监管器 3 秒内自愈；`appcenter-cli stop` → SIGTERM 优雅退出、端口释放
- [x] 升级路径（uninstall 保留数据 + 重装，v0.1.303→v0.1.305）：sqlite/订阅/面板密码/端口原样保留，
      内核凭 `core-autostart` 自动恢复，target 下 symlink 自动重建
- [x] 推广横幅移除（v0.1.306 index.html 注入）：无头 Chromium 走完「设密码→登录→
      概览」全流程，DOM 中推广锚点 0 条、无 JS 错误、截图确认无横幅且页面完整渲染
- [x] 图标圆角：ICON.PNG/ICON_256.PNG/ui 各尺寸四角透明、r≈19%，已装机验证
- [x] 侧栏 logo 对齐（v0.1.308）：无头 Chromium 实测 logo 左缘与菜单图标左缘
      delta=0，完整 logo 保留，折叠按钮在位
- [x] 同源网关（v0.1.309）：本地搭 TCP→socket 桥模拟 fnOS 网关路径，无头
      Chromium 走「网关路径打开→设密码→概览」全流程：500ms 渲染、15 次 API
      调用经网关 200、推广 0 条；直连路径回归通过（22 次 API 调用正常）
- [x] `open-box port` / `open-box password` / `open-box check`（可经镜像查到上游最新版）
- [x] `openbox-ctl pre-start` 在无配置时干净拒绝（不动系统网络）
- [x] sing-box 内核二进制本机可执行（`version` 正常）；glibc Node 24.18.0 跑通面板
- [x] 内核完整启动：用户已在面板导入订阅并启动内核（TUN/分流正常工作，冲突守护生效）
- [x] 升级至上游 v0.1.307（fpk 0.1.312→0.1.313，`OPENBOX_TAG=v0.1.307`）：uninstall 保留数据 +
      重装后 app_storage（订阅/设置/密码）101 行、rulesets、panel-port 原样保留；内核凭
      `core-autostart` 自动恢复；面板 3036 HTTP 200、meta.json=v0.1.307、内核仍为
      sing-box 1.14.1-openbox-tcp21（上游发布说明：只更面板，内核与规则库不变）
- [x] 升级至上游 v0.1.317（fpk 0.1.313→0.1.314，`OPENBOX_TAG=v0.1.317`）：uninstall 保留数据 +
      重装后 app_storage 106 行、rulesets、panel-port 原样保留；内核凭 `core-autostart`
      自动恢复；面板 3036 HTTP 200、meta.json=v0.1.317。注意：上游发布说明写「内核不变」，
      但发布资产 kernel 包实际已升至 sing-box 1.14.1-openbox-tcp22（装机验证 tcp21→tcp22），
      changelog 按实际资产改写
- [x] 侧栏菜单项间距（fpk v0.1.314→v0.1.315，fnOS 本地改动）：上游侧栏菜单项是 36px 高
      全圆角 pill、项间 0 间距紧贴；注入 `.sidebar .menu>li+li{margin-top:.5rem}` 后无头
      Chromium 实测项间距 8px（折叠态同样生效，页面内其他 .menu 不受影响）；装机后 index.html
      含注入样式、面板 3036 HTTP 200、内核经 core-autostart 恢复、数据原样保留
- [x] 升级至上游 v0.1.331（fpk v0.1.320→v0.1.321，`OPENBOX_TAG=v0.1.331`，未指定 tag 时经
      releases/latest 查到最新版）：uninstall 保留数据 + 重装后数据原样保留；meta.json=v0.1.331、
      **sing-box 1.14.1-openbox-tcp25（tcp23→tcp25 内核升级，与发布说明一致）**、Node 24.18.0、
      Geo 更新到 2026-10-15。实测：新版部署流程（cli/deploy.mjs 直跑）ok:true 10.9s，内核重启后
      以 tcp25 运行；SS 局域网代理 204；ctl running 正常；前置代理/网关双路 fnoscf 通；面板经
      前置代理 200；隧道经新链路（cloudflared→前置代理:3036→面板:3037）启动约 3 分钟边缘注册
      完成，经隧道访问面板 200（标题/注入 UI 均在）
- [x] 升级至上游 v0.1.328（fpk v0.1.319→v0.1.320，`OPENBOX_TAG=v0.1.328`）：uninstall 保留数据 +
      重装后数据原样保留；meta.json=v0.1.328、sing-box 1.14.1-openbox-tcp23（与发布说明一致）、
      Node 24.18.0、规则库更新到 10-14（geoVersion 变了）。新增「内容过滤」（设置→客户端）为面板
      侧功能，随包即用。实测：新版部署流程（cli/deploy.mjs 直跑）ok:true 11.1s；SS 局域网 204；
      ctl running 正常；前置代理/网关双路 fnoscf 通；隧道经新链路（cloudflared→前置代理:3036→
      面板:3037）启动约 2 分钟后边缘注册完成，经隧道访问面板 200（标题/API/注入 UI 均在）。
      排障记录：测试期间 cloudflared 两度「Connection terminated」实为命令行进程组清理/显式 stop
      误杀，非软件缺陷——验证隧道要用 helper 启动（supervise 托管，不受命令生命周期影响）
- [x] 修复「连不上隧道助手」（fpk v0.1.318→v0.1.319）：定位到 fnOS 应用中心(:5667)与
      FN Connect(fnos.net) 的 /api/* 请求直达面板服务端口、不过网关 socket，v0.1.326 起
      面板是完整性清单保护的 bundle 不能加路由，纯网关方案覆盖不到。方案：面板退到内网
      端口 3037，新增 openbox-front.mjs 前置代理守对外端口（/api/fnoscf/* → 助手，
      其余 → 面板；HTTP+WS；panel-port 变化自动重启），网关改直连内层面板。实测：
      3036/3037/3999 端口布局正确；fnoscf 经前置代理与网关双路都通；面板经前置代理/
      网关/LAN IP 三路 200；WS upgrade 经前置代理到达面板（401 非 502）；SS 局域网 204；
      隧道经新链路（cloudflared→前置代理→面板）最终 200 且返回面板标题（边缘注册实测
      30 秒~2 分钟，提示文案已改）；数据保留
- [x] 升级至上游 v0.1.326（fpk v0.1.317→v0.1.318，`OPENBOX_TAG=v0.1.326`）：uninstall 保留数据 +
      重装后数据原样保留；meta.json=v0.1.326、内核 sing-box 1.14.1-openbox-tcp23（与发布说明一致，
      这版说明准确）、Node 24.18.0、规则库 10-12。**适配上游硬化版**：面板服务端改为带
      hardening-manifest.json 的 minified bundle，构建脚本三个补丁改条件跳过（conflicts /
      subscription-shares 文件没了、open-box CLI 原生支持可重定位 ROOT），CF 隧道 API 转发改到
      我们自己的 openbox-gateway.mjs（/api/fnoscf/* → 助手 :3999），openbox-ctl 补 running 动作。
      实测：新版部署流程（cli/deploy.mjs 直跑）ok:true 11.2s、内核重启确认在跑；SS 局域网代理 204；
      ctl running 输出 running/exit 0；经网关起停隧道、隧道注册（kix05/http2）后面板经隧道 200
      （标题/API/注入 UI 均在）；助手常驻、数据保留
- [x] 升级至上游 v0.1.320（fpk v0.1.315→v0.1.316，`OPENBOX_TAG=v0.1.320`）：uninstall 保留数据 +
      重装后数据原样保留（共享密码未变）；内核凭 `core-autostart` 自动恢复；面板 3036 HTTP 200、
      meta.json=v0.1.320。注意：发布说明只讲升级入口修复、未提内核，但随包 kernel 资产实测已
      升至 sing-box 1.14.1-openbox-tcp23（tcp22→tcp23），规则库仍为 10-12，changelog 按实测改写
- [x] Cloudflare 隧道（fpk v0.1.316→v0.1.317，fnOS 本地新增）：随包 cloudflared 2026.10.0
      （两架构 SHA256 校验通过）+ 常驻助手 openbox-cf-tunnel.mjs（随 supervise 启停，API :3999）
      + 面板 index.mjs 注入 /api/fnoscf/* 代理路由（同源调用，HTTPS 页面不受混合内容限制）；
      无头 Chromium 实测：卡片在「后端设置」页渲染、位于「导出与导入」模块正上方（共享网络页
      不再显示，位置按用户要求调整；锚点未渲染时会先落位再自动重定位）；
      快捷/命名
      模式切换与 Token 输入框正常，UI 点「启动隧道」（经同源代理）→ badge 运行中 +
      trycloudflare.com 地址下发，经隧道访问面板 API 200（边缘注册最多约 30 秒），点「停止」
      恢复未运行；命名隧道无 Token/假 Token 均有明确错误提示且状态正确保留；
      装机后 helper 常驻、数据保留、内核 autostart 恢复。已知：本网 QUIC(7844) 不通，
      helper 已固定 `--protocol http2`

## ⚖️ 许可

- 本仓库的 fnOS 打包代码：MIT
- 随包组件：sing-box（上游 Open-Box 发行版）、Node.js（Node.js 许可证）、GeoSite/GeoIP
  （随上游发行包提供），许可与版权见各上游项目
