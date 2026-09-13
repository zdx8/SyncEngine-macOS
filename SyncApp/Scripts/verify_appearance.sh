#!/bin/bash
# 外观状态矩阵验证：静态启动 × 3 种模式 + 运行中切换 × 多方向，
# 全部用像素判据（不靠肉眼），并断言"标题栏 / 侧栏 / 详情区"三处一致。
#
# 用法：bash Scripts/verify_appearance.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/dist/sync-engine.app/Contents/MacOS/sync-engine"
APP="$ROOT/dist/sync-engine.app"
BUNDLE_ID="com.syncengine.desktop"
OUT="${TMPDIR:-/tmp}/appearance-check"

mkdir -p "$OUT"
find "$OUT" -type f -delete 2>/dev/null

# ── 像素分析：判主题一致性与强调色 ──────────────────────────────
analyze() {   # $1 = bmp 路径
  /usr/bin/python3 - "$1" <<'PY'
import struct, sys
from collections import Counter
d = open(sys.argv[1],'rb').read()
off = struct.unpack_from('<I', d, 10)[0]
w, h = struct.unpack_from('<ii', d, 18)
bpp = struct.unpack_from('<H', d, 28)[0]
row = ((bpp*w+31)//32)*4
H, up, bp = abs(h), h > 0, bpp//8
def px(x,y):
    ry = (H-1-y) if up else y
    p = off + ry*row + x*bp
    return d[p+2], d[p+1], d[p]
def lum(x,y):
    r,g,b = px(x,y); return (0.2126*r + 0.7152*g + 0.0722*b)/255.0
def avg(x0,x1,y0,y1,step=5):
    t=n=0
    for y in range(y0,y1,step):
        for x in range(x0,x1,step):
            t += lum(x,y); n += 1
    return t/n
tb = avg(0,w,8,52); sb = avg(16,400,90,600); dt = avg(480,1960,120,1300)
base = dt; ink = 0
for y in range(120,1300,3):
    for x in range(480,1960,3):
        if abs(lum(x,y)-base) > 0.25: ink += 1
c = Counter()
for y in range(0,H,2):
    for x in range(0,w,2):
        r,g,b = px(x,y)
        if (g-r)>=40 and (g-b)>=40 and g>=100: c[(r,g,b)] += 1
a = c.most_common(1)[0][0] if c else None
acc = f'#{a[0]:02X}{a[1]:02X}{a[2]:02X}' if a else 'none'
dark = lambda v: v < 0.35
light = lambda v: v > 0.6
if dark(tb) and dark(sb) and dark(dt): theme, ok = 'dark', True
elif light(tb) and light(sb) and light(dt): theme, ok = 'light', True
else: theme, ok = 'mixed', False
print(f'{theme}|{ok}|{acc}|{ink}|{tb:.3f}|{sb:.3f}|{dt:.3f}')
PY
}

shot() {   # $1 = 输出前缀；注意调用前已确保应用在跑
  local pid wid
  pid=$(pgrep -f 'sync-engine.app/Contents/MacOS/sync-engine' | head -1)
  [ -z "$pid" ] && { echo "      (进程未存活)"; return 1; }
  wid=$(xcrun swift "$ROOT/Scripts/window_probe.swift" "$pid" 2>/dev/null \
        | grep -o 'windowId=[0-9]*' | head -1 | cut -d= -f2)
  [ -z "$wid" ] && { echo "      (无窗口)"; return 1; }
  screencapture -x -o -l"$wid" "$OUT/$1.png" 2>/dev/null
  sips -s format bmp "$OUT/$1.png" --out "$OUT/$1.bmp" >/dev/null 2>&1
  analyze "$OUT/$1.bmp"
}

row() {   # $1 名称  $2 期望主题
  local name="$1" expect="$2" res theme ok acc ink
  res=$(shot "$name"); [ -z "$res" ] && return
  # analyze 输出：theme|ok|accent|ink|titlebar|sidebar|detail
  theme=$(echo "$res" | cut -d'|' -f1)
  ok=$(echo "$res" | cut -d'|' -f2)
  acc=$(echo "$res" | cut -d'|' -f3)
  ink=$(echo "$res" | cut -d'|' -f4)
  [ -z "$ink" ] && ink=0
  printf '  %-26s 主题=%-5s 一致=%-5s 强调色=%-8s 详情区墨迹=%s\n' \
    "$name" "$theme" "$ok" "$acc" "$ink"
  if [ "$theme" != "$expect" ] || [ "$ok" != "True" ]; then
    printf '    ✗ 期望主题 %s 且三处一致\n' "$expect"; FAILED=$((FAILED+1))
  fi
  if [ "$ink" -lt 100 ] 2>/dev/null; then
    printf '    ✗ 详情区几乎空白（墨迹 %s）—— 内容没画出来\n' "$ink"
    FAILED=$((FAILED+1))
  fi
}

FAILED=0
pkill -f 'sync-engine.app/Contents/MacOS/sync-engine' 2>/dev/null; sleep 2

echo "=== 静态启动（系统当前为深色）==="
for mode in light dark system; do
  defaults write "$BUNDLE_ID" AppAppearance "$mode"; sleep 3
  case "$mode" in
    light)  expect=light ;;
    dark)   expect=dark ;;
    system) expect=dark ;;   # 系统是深色
  esac
  pkill -f 'sync-engine.app/Contents/MacOS/sync-engine' 2>/dev/null; sleep 2
  open "$APP"; sleep 7
  osascript -e 'tell application "sync-engine" to activate' >/dev/null 2>&1; sleep 1
  row "static-$mode" "$expect"
done

echo ""
echo "=== 运行中切换（同一进程内发生）==="
run_transition() {   # $1 起始模式  $2 目标模式  $3 期望主题
  defaults write "$BUNDLE_ID" AppAppearance "$1"; sleep 3
  pkill -f 'sync-engine.app/Contents/MacOS/sync-engine' 2>/dev/null; sleep 2
  rm -f /tmp/sync-engine-appearance-probe.log
  open "$APP" --args --appearance-transition-test "$2"
  sleep 3
  echo "  起始 $(shot "from-$1")"
  printf '  %-26s ' "$1 → $2（切后）"
  sleep 4
  row "to-$2-from-$1" "$3"
}

run_transition light system dark
run_transition dark  system dark
run_transition system light light

pkill -f 'sync-engine.app/Contents/MacOS/sync-engine' 2>/dev/null

echo ""
if [ "$FAILED" -eq 0 ]; then echo "  全部通过"; else echo "  失败 $FAILED 项"; fi
exit "$FAILED"
