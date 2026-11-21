#!/bin/bash
# 无线扩展屏 macOS - ffmpeg 封装脚本（兼容 macOS bash 3.2）
# 将 Homebrew ffmpeg 及其全部 brew 依赖 dylib 复制进 .app，并重链为相对路径
# 用法: ./package_ffmpeg.sh <app_path>
set -euo pipefail

APP="$1"
RES="$APP/Contents/Resources"
FWS="$APP/Contents/Frameworks"
FF_SRC="${FFMPEG:-$(command -v ffmpeg || true)}"
if [ -z "$FF_SRC" ] || [ ! -x "$FF_SRC" ]; then
  echo "未找到 ffmpeg。请先 brew install ffmpeg，或用 FFMPEG=/path/to/ffmpeg 指定。" >&2
  exit 1
fi
BREW_PREFIX="$(brew --prefix 2>/dev/null || true)"

mkdir -p "$RES" "$FWS"

DEPS=()

contains() {
  local e
  for e in ${DEPS[@]+"${DEPS[@]}"}; do
    [ "$e" = "$1" ] && return 0
  done
  return 1
}

collect() {
  local lib="$1" line out
  out="$(otool -L "$lib" 2>/dev/null || true)"
  while IFS= read -r line; do
    line="$(echo "$line" | sed 's/^[[:space:]]*//' | sed 's/ (compatibility.*//')"
    # 跳过 otool 输出的二进制自身行（如 /opt/homebrew/bin/ffmpeg:）
    [ "$line" = "$lib:" ] && continue
    case "$line" in
      /opt/homebrew/*|/usr/local/*)
        if ! contains "$line"; then
          DEPS+=("$line")
          collect "$line"
        fi
        ;;
    esac
  done <<< "$out"
}

collect "$FF_SRC"
echo "收集到 ${#DEPS[@]} 个 brew 依赖 dylib"

cp -f "$FF_SRC" "$RES/ffmpeg"
chmod 755 "$RES/ffmpeg"

for lib in "${DEPS[@]}"; do
  name="$(basename "$lib")"
  cp -f "$lib" "$FWS/$name"
  chmod 755 "$FWS/$name"
done

# 重链 ffmpeg（位于 Resources，依赖指向 ../Frameworks）
for lib in "${DEPS[@]}"; do
  name="$(basename "$lib")"
  install_name_tool -change "$lib" "@executable_path/../Frameworks/$name" "$RES/ffmpeg" 2>/dev/null || true
done

# 重链 dylib 自身
for lib in "${DEPS[@]}"; do
  name="$(basename "$lib")"
  dylib="$FWS/$name"
  install_name_tool -id "@rpath/$name" "$dylib" 2>/dev/null || true
  for dep in "${DEPS[@]}"; do
    depname="$(basename "$dep")"
    install_name_tool -change "$dep" "@loader_path/$depname" "$dylib" 2>/dev/null || true
    depdir="$(basename "$(dirname "$dep")")"
    install_name_tool -change "/opt/homebrew/opt/$depdir/lib/$depname" "@loader_path/$depname" "$dylib" 2>/dev/null || true
  done
done

echo "=== 重签 ffmpeg 与 dylib（install_name_tool 会使签名失效）==="
codesign --force -s - "$RES/ffmpeg" 2>/dev/null || true
for lib in "${DEPS[@]}"; do
  codesign --force -s - "$FWS/$(basename "$lib")" 2>/dev/null || true
done

echo "=== 验证 ffmpeg 依赖 ==="
otool -L "$RES/ffmpeg" | head -12
echo "=== 运行验证 ==="
"$RES/ffmpeg" -hide_banner -version | head -1
echo "OK: ffmpeg 封装完成"
