# 用 sqflite 而不是 drift 做本地存储

本地库原本选的是 drift，但它在**本机构建不出来**：drift 2.35 要求 `sqlite3 ^3.4.0`，而那个包已经迁到 Dart 的 **native assets**，构建时要从 `github.com/simolus3/sqlite3.dart/releases` 下载预编译库——本机 github 不可达（`SocketException … signal timeout`，errno 121）。`drift_flutter` 的 pubspec 注释里把话说死了：「不想让用户依赖 0.5.x，因为 sqlite3 已迁到 hooks」，所以退回旧版这条路是关着的；再往下退要连 `drift_dev`、`build_runner`、`analyzer` 一起退到与 Flutter 3.47 工具链不匹配的版本（求解器会直接报冲突）。

改用 `sqflite`：用平台自带的 SQLite，不走 native assets、不需要 codegen。表结构与 SQL 原样保留，只是把 drift 的类型化 API 换成手写 SQL。

## Consequences

- 少了 drift 的类型安全与查询编译器；换来的是**在本机能构建**、且不依赖 github。
- 那两条关键查询（「按最后观看时间倒序」「按剧聚合取最新一集」）本来就是手写 SQL（drift 的 `customSelect`），所以几乎没损失。
- 以后若 github 可达，换回 drift 的成本主要在 `lib/data/database.dart` 一个文件——表结构与查询都在那里。
- **另一个环境坑一并记在这里**：Kotlin 增量编译在本机会稳定报
  `Could not close incremental caches … Storage is already registered`（`shared_preferences_android` 的 `compileDebugKotlin`），清 `build/` 与 `flutter clean` 都不管用。已在 `android/gradle.properties` 关掉 `kotlin.incremental` 并用 `kotlin.compiler.execution.strategy=in-process` 绕开，代价是构建慢一些。
- **教训**：`isCacheableRequest` 那类「哪些请求不缓存」的清单，和这里的「哪些依赖不从 github 拉」一样，都是环境约束写进代码的地方。环境一变先看这两处。
