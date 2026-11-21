# Android 端 · AirPlay + 无线扩展屏接收

这是「无线扩展屏」的安卓接收端源码，基于 GPL-3.0 的开源项目
[jqssun/android-airplay-server](https://github.com/jqssun/android-airplay-server)
（其底层是 [UxPlay](https://github.com/FDH2/UxPlay) + MediaCodec）。

它同时支持两条链路：

| 链路 | 协议 | 谁发送 |
|---|---|---|
| iPhone / iPad / Mac 隔空播放 | AirPlay / RAOP | 系统自带「屏幕镜像」 |
| Mac / Windows / 网页投屏 | `WXESMIRROR` over TCP 9000 | 本仓库 `mac/`、`windows/`、`web/` |
| 反向控制 | 同一条 TCP 连接上的 type=4/5 | 接收端 → 发送端 |

## 本仓库新增的模块

```
app/src/main/kotlin/io/github/jqssun/airplay/mirror/
├── MirrorReceiver.kt        WXESMIRROR 接收：握手、拆帧、交给 VideoRenderer 硬解
├── MirrorActivity.kt        接收界面：SurfaceView + 本机 IP + 触摸反控
├── MirrorSender.kt          安卓作为发送端：MediaProjection + MediaCodec（可选）
└── RemoteCtrlService.kt     无障碍反控：点击 / 滑动 / 滚屏 / 输入
```

其它改动：

- `AndroidManifest.xml` 注册 `MirrorActivity` 与无障碍服务；
- 主页右下角新增「扩展屏」按钮，进入接收界面；
- `applicationId` 改为 `com.wuxian.extscreen`，与发布的 APK 一致；
- 新增 `res/xml/accessibility_config.xml` 与中文字符串。

## 构建

### 1. 环境

- Android Studio（或 Android SDK + JDK 17）
- Android NDK `27.0.12077973`（`app/build.gradle.kts` 中指定）
- CMake（Android Studio 自带）
- 约 10 GB 磁盘空间（FFmpeg / OpenSSL 首次编译较久）

### 2. 拉取原生依赖

```bash
cd android
# git clone 的情况
git submodule update --init --recursive

# 如果下载的是 zip（没有 .git）
./setup-submodules.sh
```

四个子模块：UxPlay、libplist、openssl-cmake、FFmpeg。
首次构建会编译 FFmpeg/OpenSSL，Apple Silicon 上通常需要 20–40 分钟。

### 3. 编译

```bash
# 在 android/ 下
echo "sdk.dir=$HOME/Library/Android/sdk" > local.properties
./gradlew assembleDebug
# 产物：app/build/outputs/apk/debug/app-debug.apk
```

也可以直接用 Android Studio 打开 `android/` 目录，等待 Gradle Sync 后运行。

> 如果你只想改 WXES 接收端，不关心 AirPlay，可以只保留 `mirror/` 下的
> Kotlin 代码，把 `VideoRenderer` 换成 `MediaCodec` + `SurfaceView` 的
> 最小实现；协议文档见 [`../docs/protocol.md`](../docs/protocol.md)。

## 权限

- **本地网络 / Wi-Fi**：发现 AirPlay 发送端、监听 9000 端口；
- **通知**：前台服务常驻通知（Android 13+ 需要授权）；
- **无障碍**：反向控制（点击、滑动、文字输入），默认关闭，需用户手动开启；
- **录屏**：仅当使用「安卓作为发送端」时需要 MediaProjection 授权。

## 与发布 APK 的关系

- Release 中的 `无线扩展屏-v1.6.apk` 是作者用同一代码线构建的安装包，
  额外包含 DLNA 接收等实验功能；本目录聚焦可维护的 AirPlay + WXES 主链路。
- APK 使用作者签名。自己构建的 APK 签名不同，安装前需要先卸载旧版。
- 上游 AirPlay 接收器为 GPL-3.0；本目录整体也按 GPL-3.0 发布，
  保留上游 `LICENSE` 与版权声明。

## 已知限制

- AirPlay 的 DRM 内容（Apple TV App 等）无法播放；
- 部分安卓设备的 H.264 解码器对 `baseline` 以外的档次支持不一致，
  发送端默认使用 baseline + 无 B 帧，兼容性最好；
- 反向控制的文字输入依赖无障碍节点，部分自绘输入框可能不生效；
- 没有做端到端加密，仅建议在可信局域网使用。

## 上游

- [jqssun/android-airplay-server](https://github.com/jqssun/android-airplay-server)
- [FDH2/UxPlay](https://github.com/FDH2/UxPlay)
- [FFmpeg](https://ffmpeg.org/)
