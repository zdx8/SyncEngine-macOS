#!/usr/bin/env bash
#
# 把 SwiftPM 产出的裸可执行文件组装成可双击运行的 .app。
#
# SwiftPM 只产二进制，不管 bundle —— Info.plist、图标、签名都要自己来。
#
# 用法：
#   bash Scripts/build_app.sh                # 本机架构
#   bash Scripts/build_app.sh arm64          # 指定架构
#   bash Scripts/build_app.sh x86_64
#   bash Scripts/build_app.sh universal      # arm64 + x86_64 合成一个
#
# 产物：dist/sync-engine.app
# 注意几个已知的坑（技术方案 9.4 有完整说明）：
#   * SwiftPM manifest 的默认沙箱在受限 shell 里会失败 → 加 --disable-sandbox
#   * bash 3.2 下变量紧跟中文必须写 ${VAR}，否则会把全角字节并进变量名
#   * 图标缓存以 CFBundleVersion 为键 → 版本号带上时间戳
#   * 不要用 rm -rf 清理旧包 → 改为覆盖写入

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
PROJECT_ROOT="$(pwd)"

# 交付给用户的程序名（bundle 名与 bundle 内可执行文件名同取此值）。
APP_NAME="sync-engine"
# SwiftPM 产出的可执行文件名 —— 它取自 Package.swift 的 **target** 名，
# 不受 product 名影响（实测过），所以这里必须与 target 名一致。
SWIFT_BIN_NAME="SyncApp"
BUNDLE_ID="com.syncengine.desktop"
APP_VERSION="1.0.0"
# 版本号带时间戳：CFBundleVersion 变了，系统的图标缓存才会失效。
# 否则替换 AppIcon.icns 后访达与 Dock 永远显示旧图标，极易被误判成"代码没生效"。
BUILD_NUMBER="$(date +%y%m%d.%H%M)"

DIST_DIR="$PROJECT_ROOT/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"

GRN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RST=$'\033[0m'
[ -t 1 ] || { GRN=""; RED=""; DIM=""; RST=""; }

# 目标架构。native = 本机架构；arm64 / x86_64 供产出发行版安装包用
# （见 Scripts/make_dmg.sh，双架构需依次执行两次）。
ARCH="${1:-native}"
[ "$ARCH" = "--universal" ] && ARCH="universal"

BUILD_ARGS=(build -c release --disable-sandbox)
case "$ARCH" in
  universal) BUILD_ARGS+=(--arch arm64 --arch x86_64) ;;
  ""|native) : ;;
  *)         BUILD_ARGS+=(--arch "$ARCH") ;;
esac

printf '构建 Swift 包（release · 架构 %s）\n' "$ARCH"
swift "${BUILD_ARGS[@]}" 2>&1 | grep -vE '^\[[0-9]+/' | tail -5

# --show-bin-path 必须用与 build **完全相同**的参数取；
# 带 --arch 时它返回的是 .build/apple/Products/Release/，不是 .build/release/。
BIN_PATH="$(swift "${BUILD_ARGS[@]}" --show-bin-path)"
EXECUTABLE="$BIN_PATH/$SWIFT_BIN_NAME"

if [ ! -x "$EXECUTABLE" ]; then
  printf '%s✗ 未找到可执行文件：%s%s\n' "$RED" "$EXECUTABLE" "$RST" >&2
  exit 1
fi

printf '组装 app bundle\n'
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
# 覆盖写入而不是先删再建：某些环境的安全护栏会拦截批量删除，
# 导致 set -e 下的脚本直接中断。
cp -f "$EXECUTABLE" "$APP_DIR/Contents/MacOS/$APP_NAME"

# ── 图标
#
# 缓存判据必须带上源文件的时间戳：只判"文件在不在"的话，
# 改了品牌色重跑打包会**沿用旧图标**，看着像"改了没生效"。
# （图标本身还有一层系统缓存，用时间戳版本号 + lsregister 处理，见下面。）
ICNS="$PROJECT_ROOT/Resources/AppIcon.icns"
ICON_SOURCE="$PROJECT_ROOT/Scripts/make_icon.swift"
if [ ! -f "$ICNS" ] || [ "$ICON_SOURCE" -nt "$ICNS" ]; then
  printf '  %s生成应用图标（品牌色取自 make_icon.swift）%s\n' "$DIM" "$RST"
  mkdir -p "$PROJECT_ROOT/Resources"
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  swiftc -O -o /tmp/syncapp-make-icon "$ICON_SOURCE"
  /tmp/syncapp-make-icon "$ICONSET" >/dev/null
  iconutil -c icns "$ICONSET" -o "$ICNS"
  rm -rf "$(dirname "$ICONSET")"
fi
cp -f "$ICNS" "$APP_DIR/Contents/Resources/AppIcon.icns"

# ── Info.plist
# 用不加引号的 heredoc 插值，避免版本号在两处维护。
cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>${APP_NAME}</string>
	<key>CFBundleIdentifier</key>
	<string>${BUNDLE_ID}</string>
	<key>CFBundleName</key>
	<string>sync-engine</string>
	<key>CFBundleDisplayName</key>
	<string>sync-engine</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${APP_VERSION}</string>
	<key>CFBundleVersion</key>
	<string>${BUILD_NUMBER}</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.utilities</string>
	<!--
	  传输安全策略。

	  必须放开明文 HTTP：WebDAV 的典型对手是家用 NAS，而群晖/威联通出厂
	  只提供 http 的 WebDAV 端点，自签证书的 https 也不在少数。默认策略
	  下这两类服务器会直接连不上，而用户看到的错误是「传输安全策略」——
	  与"地址填错了"难以区分，排查成本很高。

	  取舍：这确实降低了传输层的强制保护。缓解措施有三条：
	    1. 只对用户**明确填写**的地址发起连接，不做任何自动发现
	    2. 任务编辑器在地址以 http:// 开头时给出明文传输提示
	    3. 自签名证书需要用户显式勾选才放行，且会写入探测结果
	  若将来只面向企业内网部署，应改为 NSAllowsLocalNetworking 并
	  要求所有端点为 https。
	-->
	<key>NSAppTransportSecurity</key>
	<dict>
		<key>NSAllowsArbitraryLoads</key>
		<true/>
	</dict>
</dict>
</plist>
PLIST

# ── 签名
# ad-hoc 签名只能保证本机运行；分发给他人需要开发者证书 + 公证（见技术方案第 10 节）。
codesign --force --deep --sign - "$APP_DIR" 2>/dev/null

printf '  %s✓%s %s\n' "$GRN" "$RST" "$APP_DIR"
printf '     %s大小 %s%s\n' "$DIM" "$(du -sh "$APP_DIR" | cut -f1)" "$RST"
lipo -archs "$APP_DIR/Contents/MacOS/$APP_NAME" 2>/dev/null | sed "s/^/     架构 /" || true

# 主动失效图标缓存（否则可能仍显示旧图标）
touch "$APP_DIR" "$APP_DIR/Contents/Resources/AppIcon.icns"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$APP_DIR" >/dev/null 2>&1 || true

printf '\n下一步：\n'
printf '  运行          open "%s"\n' "$APP_DIR"
printf '  无界面自检    "%s/Contents/MacOS/%s" --selfcheck\n' "$APP_DIR" "$APP_NAME"
