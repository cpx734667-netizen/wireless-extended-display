#!/usr/bin/env bash
# 初始化 Android 原生依赖（UxPlay / libplist / openssl-cmake / FFmpeg）
# 如果你是用 git clone 下来的，优先用：
#   git submodule update --init --recursive
# 如果是下载的 zip（没有 .git），本脚本会直接浅克隆。
set -euo pipefail
cd "$(dirname "$0")"

clone_if_empty() {
  local url="$1" path="$2"
  if [ -n "$(ls -A "$path" 2>/dev/null || true)" ]; then
    echo "skip $path (not empty)"
    return
  fi
  echo "clone $url -> $path"
  git clone --depth 1 "$url" "$path"
}

clone_if_empty https://github.com/FDH2/UxPlay.git app/src/main/cpp/third_party/UxPlay
clone_if_empty https://github.com/libimobiledevice/libplist.git app/src/main/cpp/third_party/libplist
clone_if_empty https://github.com/viaduck/openssl-cmake.git app/src/main/cpp/third_party/openssl-cmake
clone_if_empty https://github.com/FFmpeg/FFmpeg.git app/src/main/cpp/third_party/ffmpeg

echo "OK. 现在可以在 Android Studio 打开 android/，或执行 ./gradlew assembleDebug"
