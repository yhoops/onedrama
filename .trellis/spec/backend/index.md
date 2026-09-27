# 数据 / 协议层规范（backend）

> 本目录的「backend」= 非 UI 的 Dart 代码。UI 规范在 `.trellis/spec/frontend/`。

---

## 这一层指什么

| 路径 | 职责 |
|------|------|
| `packages/hongguo_dart/` | 红果协议真相层：签名、JSON 解析、取流、CENC 密钥与样本解密。对照仓库里的 Go `hongguo/`，靠共享 fixtures 双向比对防分叉（`docs/adr/0003`）。**不碰 UI、不碰播放器。** |
| `lib/data/` | App 数据层：sqflite 本地库、带缓存的 dio、prefs 存储、封面/剧集/榜单缓存、Riverpod provider、可单测的纯函数（`library_tabs`、`catalog_pager` 分页状态机）。 |
| `lib/player/` | Kotlin ExoPlayer 薄插件的 Dart 面：`cenc_player`（MethodChannel）、`cenc_header`（读 moov）、`decrypt_plan`（解密计划二进制编码）。控件/手势全在 UI 层（`docs/adr/0002`）。 |
| `android/app/src/main/kotlin/` | 薄插件本体：只持有 ExoPlayer、纹理、解密数据源，零 Kotlin UI。 |

---

## 规范索引

| 文档 | 覆盖 |
|------|------|
| [目录结构](./directory-structure.md) | 三块 Dart 的分工、协议包布局、命名 |
| [数据库](./database-guidelines.md) | sqflite（非 drift）、建表/升级、手写 SQL、prefs vs 库 |
| [错误处理](./error-handling.md) | dio 契约、协议异常、App→网页降级、防御式 JSON、缓存入场条件 |
| [题材筛选](./catalog-themes.md) | 题材词表与 `/category/<类型>/<题材>` 服务端筛选契约、本地筛/排、跨筛选竞态守卫 |
| [日志](./logging-guidelines.md) | 无框架、`debugPrint` 带标签取证痕迹、`avoid_print` |
| [质量](./quality-guidelines.md) | flutter_lints、不可变模型、纯函数抽取、原因优先注释、测试底线 |

---

**语言**：本项目全部注释、ADR、`CONTEXT.md` 均为中文，规范随之用中文，便于子代理与代码风格对齐。
