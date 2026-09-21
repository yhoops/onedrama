# Go 包留在仓库里当「协议真相」，用共享 fixtures 双向比对防分叉

按 [ADR-0001](0001-dart-rewrite-instead-of-gomobile.md)，Dart 和 Go 是两份实现且没有任何自动比对；签名或解析写错不会让测试红，只会让真机上搜不到剧。所以穿刺和日常调试时把真实响应（App JSON、网页 HTML、备用接口响应）抓下来存成 fixtures，Go 和 Dart 各跑一遍解析并断言两端输出相等；签名、SM3、CENC 密钥还原用固定向量。Go 改一行，Dart 测试立刻红。

## Considered Options

- **只把 `hongguo_test.go` 里的签名 / SM3 / ID 向量抄成 Dart 测试**：最省事，但只覆盖纯函数，网页解析漂移测不到——而网页 `_ROUTER_DATA` 结构一变，分类、搜索、榜单会一起挂。
- **Dart 自己写单测，Go 只当阅读参考**：最快，也最容易静默分叉。

## Consequences

fixtures 里会有真实剧集 ID 和设备参数，仓库若不外发则无所谓；将来若要公开，需要先清洗。
