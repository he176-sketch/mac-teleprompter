# 电脑提词器 · MacTeleprompter

macOS 原生浮动提词器：窗口置顶、跨桌面、可调透明度与字号，用中文语音识别按稿件位置高亮滚动。

配套改造过的 Recordly 后，录屏时提词器窗口**不会进入成片**——开录前它的进程会被加入 ScreenCaptureKit 的排除列表，摄像头画面与麦克风音轨照常保留。

> A macOS floating teleprompter that follows your voice, plus a Recordly patch that keeps the teleprompter out of screen recordings.

## 为什么做这个

手机上有能用的提词器，但录桌面课程、做直播时没有对应工具：要么提词器被录进画面，要么来回切窗口打断节奏。这个项目只解决一件事——**一直在眼前，但永远不在成片里**。

## 构建

只依赖本机 Xcode 命令行工具，不需要 Xcode 工程文件：

```sh
./build.sh
open build/MacTeleprompter.app
```

首次开始跟读时，macOS 会请求**麦克风**与**语音识别**权限。

## 使用

1. 启动 `MacTeleprompter`，打开稿件，调整透明度、字号、窗口位置；
2. 启动改造版 Recordly，选择「屏幕」开始录制；
3. 录制结束，提词器窗口已被排除，成片里只有你的画面。

快捷键与穿透：

- `⌘⇧T` 切换鼠标穿透
- 穿透状态下按 `Esc` 恢复鼠标操作
- 菜单栏「提」始终保留「关闭鼠标穿透」「显示提词器」「退出」

## Recordly 配合改动

原版 Recordly 会把提词器一起录进去。改动很小：开录前把 `MacTeleprompter` 进程加入 ScreenCaptureKit 排除列表，做法见 [docs/recordly-integration.md](docs/recordly-integration.md)。

> Recordly 采用 AGPL-3.0，本仓库**不分发**其源码，只提供改动说明；需要完整录屏功能请基于上游自行构建。

## 目录

```
Sources/TeleprompterApp.swift    窗口、菜单、权限、鼠标穿透
Sources/ScriptFollower.swift     累计转写匹配器（漏字/错字/重复/停顿续读）
Resources/Info.plist
build.sh                         直接调用 swiftc 打包 .app
```

## 已知缺陷

见 [DEFECTS.md](DEFECTS.md)。当前版本适合 1–3 分钟短视频录制；**十分钟以上长录尚未验收**。

## 许可证

MIT
