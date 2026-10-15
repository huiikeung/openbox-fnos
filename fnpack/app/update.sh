#!/bin/sh
# Open-Box fnOS 版 —— 升级入口占位
#
# 上游 Open-Box 的面板内置升级（update.sh）面向 OpenWrt / Debian 的
# /opt/open-box 布局与 systemd 单元，与 fnOS 应用目录（fpk 升级时整体替换）
# 不兼容，因此本版本禁用了面板内升级：请通过 fnOS「应用中心」升级
# Open-Box，订阅、规则、面板密码等数据目录内容会保留。
#
# GeoSite / GeoIP 数据随每个 fpk 版本一起更新。

echo "Open-Box (fnOS 版) 不支持在面板内升级。" >&2
echo "请通过 fnOS「应用中心」升级 Open-Box；订阅、规则与面板密码会保留。" >&2
exit 1
