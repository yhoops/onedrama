# hongguo_dart

红果协议层：**签名、ID、CENC 密钥还原与样本解密、网页解析、分类 / 推荐 / 榜单 / 搜索、三级取流**。
纯 Dart，不碰 UI、不碰播放器，可以脱离 Flutter 单测。

这个包是根项目 `onedrama` 的内部依赖（`publish_to: 'none'`），**不是放在 pub.dev 上的库**。

## 与 Go 版的关系

`hongguo/` 是同一套协议的 Go 参考实现，留在仓库里当**协议真相**——两边靠共享 fixtures
双向比对防分叉，签名写错会让 Dart 测试立刻红。理由见 `docs/adr/0001` 与 `docs/adr/0003`。

比 Go 多出来的只有 CENC 样本解密（`lib/src/cenc.dart`）：Go 那边明确「只给密钥、不解封装」，
而这边的播放器必须自己解（见 `docs/adr/0005`）。

## 用法

```dart
final client = HongguoClient();
final detail = await client.fetchDetail('753216');
final media  = await client.resolveMedia('753216', '748001');
```

公开 API 见 `lib/hongguo_dart.dart` 的 export 列表，每个文件开头的注释写了它负责哪一段。
纯函数（签名、解密、页面解析）可以单独调用，不必走 `Client`。

## 自检

```bash
dart pub get
dart test                              # 契约测试：32 passed, 7 skipped
LIVE=1 dart test test/live_test.dart   # 联网冒烟：真的打红果接口
```

那 7 条默认跳过的是联网冒烟，**是「签名是否被服务端接受」的唯一硬证据**：契约测试只能保证
Dart 和 Go 一致，两边一起错只有它会红。

`tool/` 下是离线验证脚本，**都不需要手机**，每个文件开头写了它的判据：

```bash
dart run tool/verify_decrypt.dart [series_id]   # 几何自检 + 枚举密码学变体，判据 walkAvcc
dart run tool/decrypt_to_file.dart <输出.mp4>   # 解出干净 MP4，交 FFmpeg 当裁判
dart run tool/inspect_media.dart                # 这一集到底是哪种加密
dart run tool/inspect_samples.dart              # NAL 长度前缀是明文还是密文
dart run tool/probe.dart [series_id...]         # 签名能不能被服务端接受 + dump 响应形状
dart run tool/inspect_ranking.dart [board_id]   # 榜单解析逐级查找结果
```

（`inspect_*` / `decrypt_to_file` 默认路径里带 `E:/Env/tmp/...`，那是本机的临时目录。）
