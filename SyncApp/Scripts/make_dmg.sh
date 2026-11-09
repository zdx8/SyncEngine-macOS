#!/usr/bin/env bash
#
# 把应用包打成可分发的 DMG 安装包。
#
# 用法：
#   bash Scripts/make_dmg.sh [版本号] [native|arm64|x86_64|universal]
#
#   版本号缺省时从 build_app.sh 的 APP_VERSION 读取 —— 避免版本号在两处维护，
#   那是最容易产生"应用内显示 1.0.0、文件名写着 1.0.1"这类不一致的地方。
#   产物：dist/sync-engine-v<版本号>-<架构>.dmg
#
# 发行双架构时依次执行（每次都会重新构建，所以顺序执行才对应正确架构）：
#   bash Scripts/make_dmg.sh 1.0.0 arm64
#   bash Scripts/make_dmg.sh 1.0.0 x86_64
#
# 说明：镜像内只放 sync-engine.app，卷名固定 sync-engine，UDZO 压缩。
#   与账号下其他 macOS 项目的发布形态保持一致。

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCH="${2:-native}"

DEFAULT_VERSION="$(sed -n 's/^APP_VERSION="\(.*\)"/\1/p' "$ROOT/Scripts/build_app.sh" | head -1)"
VERSION="${1:-$DEFAULT_VERSION}"

if [ -z "$VERSION" ]; then
  echo "错误：未能确定版本号，请显式传入，例如：bash Scripts/make_dmg.sh 1.0.0 arm64" >&2
  exit 1
fi

# native 下用本机架构标注文件名，与显式架构的命名（-arm64 / -x86_64）一致。
if [ "$ARCH" = "native" ]; then
  LABEL="$(uname -m)"
else
  LABEL="$ARCH"
fi

APP_NAME="sync-engine"
APP_DIR="$ROOT/dist/${APP_NAME}.app"
OUT="$ROOT/dist/${APP_NAME}-v${VERSION}-${LABEL}.dmg"

# 注意：变量引用紧跟非 ASCII 字符时必须写 ${VAR}。
# macOS 自带 bash 3.2 会把全角字符的首字节并进变量名，导致"未定义变量"而中断。
printf '==> 构建 %s（架构 %s）\n' "$APP_NAME" "$ARCH"
bash "$ROOT/Scripts/build_app.sh" "$ARCH"

if [ ! -d "$APP_DIR" ]; then
  echo "错误：未找到 $APP_DIR" >&2
  exit 1
fi

printf '==> 打包 DMG\n'
# 同名旧产物先移除：hdiutil 覆盖已存在镜像时的行为不直观，显式清理更可控。
rm -f "$OUT"
hdiutil create -volname "$APP_NAME" -srcfolder "$APP_DIR" -ov -format UDZO "$OUT" >/dev/null

printf '==> 完成：%s\n' "$OUT"
printf '    大小：%s\n' "$(du -h "$OUT" | cut -f1)"
printf '    架构：%s\n' "$(lipo -archs "$APP_DIR/Contents/MacOS/${APP_NAME}" 2>/dev/null || echo 未知)"
printf '    校验：%s\n' "$(shasum -a 256 "$OUT" | cut -d' ' -f1)"
