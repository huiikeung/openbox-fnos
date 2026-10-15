#!/bin/sh
# Open-Box fnOS 版 —— 卸载入口占位
#
# 卸载由 fnOS 应用中心完成（可选保留数据目录）。本脚本不执行任何操作，
# 仅提示正确路径，避免误删 fnOS 应用目录之外的内容。

echo "Open-Box (fnOS 版) 请通过 fnOS「应用中心」卸载。" >&2
echo "卸载时可选是否保留 /vol1/@appdata/fnnas.openbox（订阅、规则、面板密码）。" >&2
exit 1
