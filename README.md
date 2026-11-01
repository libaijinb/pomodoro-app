# 番茄钟 Pomodoro

iOS 风格的专注计时应用，同一份 Flutter 代码，支持 Android（已实测）和 iOS（需 macOS + Xcode 构建）。

## 功能

- 番茄计时：专注 25 分钟 / 短休 5 分钟 / 长休 15 分钟，4 个番茄后长休
- 任务：新建任务、设为当前任务，完成一个番茄计入该任务
- 今日专注目标：默认 120 分钟，可调 30–480 分钟
- 统计：本周完成、本周专注、连续纪录、今日完成、最近 7 天曲线、最近番茄记录
- 白噪音：白噪音、雨声、篝火，本地合成音频，可调音量
- 震动：开始、暂停、阶段结束等有触觉反馈，可在设置里关闭
- 液体玻璃：基于 liquid_glass_widgets 的 iOS 26 风格玻璃，计时卡、dock、浮窗均为玻璃面；第一屏组件不单开整页，全部以从来源浮出的浮窗打开，长按出浮窗，点按只调可见项
- 主题：设置页可切换深色与谷歌白，切换后持久保存
- 120Hz：请求高刷新率（设备支持时生效，非强制锁定）

## 快速开始

```bash
flutter pub get
flutter run
# Android 发布包（arm64 分包）：
flutter build apk --release --split-per-abi
```

iOS 需要 macOS + Xcode，无法在 Linux 上构建 IPA。

## 签名说明（重要）

本仓库**不包含**任何签名密钥：

- `android/app/pomodoro-release.keystore` 和 `android/key.properties` 均未上传，也不在本仓库中。
- 发布包的 `android/app/build.gradle.kts` 引用 `key.properties` 中的 release 签名配置；没有自己的 `key.properties` 时，请先按 [Flutter 官方签名指南](https://flutter.dev/to/reference-keystore) 生成自己的 keystore 和 `key.properties`，再构建 release 包；或直接构建 debug 包调试。

## 已知限制

- 计时器在应用被系统杀掉后不会继续运行，也没有系统闹钟兜底。
- 白噪音未在所有真机上逐一耳测；音量与系统静音设置有关。
- 本仓库初次上传时，二进制资源文件（启动图标、Web 图标、Gradle wrapper jar、白噪音 WAV）因上传通道只支持 UTF-8 文本而未包含，文字源码齐全；需要这些资源时请从 Flutter 模板或原工程补齐，`assets/audio/` 下应有 `white.wav`、`rain.wav`、`fire.wav` 三个文件。

## 技术栈

Flutter + Dart，依赖见 `pubspec.yaml`：cupertino_icons、audioplayers、shared_preferences、refresh_rate、liquid_glass_widgets。
