# 协议在 Dart 里重写，而不是把 Go 编进 APK

`hongguo/` 已经是一份能跑的 Go 解析实现，但它返回 `map[string]any` / `json.RawMessage`，gomobile 导不出这类类型；改成 JSON 门面或 c-shared + FFI 都要在 Windows 上配 Android NDK 做交叉编译。所以协议层按 `hongguo` 的逻辑在 `packages/hongguo_dart` 用 Dart 重写，`hongguo/` 留在仓库里当协议真相和测试预言，不进 APK。

## Considered Options

- **gomobile + JSON 门面**：协议不用重写，但要在 Windows 上装 NDK，签名算法和设备号也随二进制进包。
- **c-shared + Dart FFI**：比 gomobile 可控，同样要 NDK。
- **手机壳 + 家里 Go 服务**：APK 里没有签名，但出门没那台机器就废，和「安卓客户端」目标冲突。

## Consequences

从此是两份实现，会静默分叉——签名写错的表现是真机上「搜不到剧」，而不是测试红。防分叉的做法见 [ADR-0003](0003-go-package-as-protocol-truth-with-fixtures.md)。
