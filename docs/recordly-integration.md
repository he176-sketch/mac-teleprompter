# 让提词器不出现在录屏里

Recordly（AGPL-3.0）默认会把屏幕上的一切都录进去，包括浮动提词器窗口。

解决思路不是隐藏窗口，而是在 **ScreenCaptureKit 层**把提词器进程排除掉。这样：

- 提词器在你的屏幕上照常显示、照常滚动；
- 录制内容里没有它；
- 摄像头画面、麦克风音轨不受影响。

## 改动位置

在 Recordly 开始录制、构建 `SCContentFilter` 的地方，追加一个排除项（bundle id 换成你自己的）：

```swift
// 开录前，把提词器进程加入排除列表
let teleprompter = SCRunningApplication(
    bundleIdentifier: "com.yourname.MacTeleprompter"
)

let filter = SCContentFilter(
    display: display,
    excludingApplications: [teleprompter],
    exceptingWindows: []
)
```

关键点：

1. **必须在每次开录时重新构建 filter**，进程重启后 `SCRunningApplication` 会失效；
2. 提词器需要先启动，否则排除项匹配不到（本项目的使用顺序就是先开提词器再开录）；
3. `bundleIdentifier` 必须与 `Resources/Info.plist` 中的 `CFBundleIdentifier` 完全一致。

## 为什么不分发改造版

Recordly 是 AGPL-3.0。分发二进制或源码都要求以同样许可提供完整对应源码，维护成本高、也容易与上游版本脱节。所以这里只给改动方法，由使用者自行构建。

如果你只是自己用：改完 `npm run build`（或上游对应命令）后，把产物放到 `/Applications/`，然后按 README 的顺序启动即可。
