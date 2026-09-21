# 在客户端按 CENC 规则解密，而不是交给 ExoPlayer 的 DRM

红果 App 源的每个视频样本都是整段 AES-128-CTR 加密的，**连 NAL 长度前缀都是密文**。media3 的 `Mp4Extractor` 在 `nalUnitLengthFieldLength != 0` 时无条件把 length-prefixed NAL 转成 Annex-B——读源码确认，**代码里没有任何加密分支**——于是把密文当长度读，抛 `ParserException: Invalid NAL length`（真机实测）。补 `pssh`（已实现并跑过，无效）、走 ClearKey、用设备上确实存在的 `libdrmclearkeyplugin.so`，都改变不了这一点：提取器必须能在明文里看到 NAL 结构。

所以 [ADR-0002](0002-thin-exoplayer-plugin-owns-cenc.md) 的「薄插件注入密钥」和它的「失败则只播明文」回退**都不成立**——App 源正片全是加密的，只播明文等于片库为空。改为：Dart 侧解析 `moov` 建样本索引与 IV，Kotlin 侧做一个**解密数据源**，按样本 AES-CTR 解出来再喂给 ExoPlayer；同时把 `moov` 里的加密盒子换成**等大的 `free` 盒子**（`encv` → `avc1` 原地改名），总长不变、`stco` 偏移一个都不用重算。

## 实测形态

| 项 | 值 |
| --- | --- |
| `schm` | `cenc`（AES-CTR） |
| 加密粒度 | **整个样本**，无 subsample（`senc` flags=0） |
| IV | `senc` 逐样本 **8 字节**，逐样本 +1；`saiz` 每样本恰好 8 |
| 语义 | counter 块 = `IV ‖ 00000000_00000000`，低 8 字节按大端递增 |
| `pssh` | **不存在**（所以 ExoPlayer 压根不建 DRM 会话） |

## Consequences

- 不依赖 `pssh`、不依赖 `MediaDrm`、不依赖设备的 ClearKey 插件——全在自己手里，
  而且可以完全离线验证。
- **CTR 的 keystream 必须用 AES 的加密方向生成**（`ks = AES_encrypt(counter)`）。
  写成解密方向会得到逆密码流，结果静默全错——这里踩过一次，见
  `lib/src/cenc.dart` 的注释。
- 验证手段两条，都很硬：① 解密后的 AVCC 样本必须能按 4 字节长度前缀严丝合缝走完
  （`walkAvcc`）；② 必要时用 FFmpeg `-decryption_key` 当裁判。第二条在本机可用，
  而且原项目本来就用 FFmpeg 解 CENC，等于拿参考实现对照。
- 几何自检（所有样本的 `[offset, end)` 必须严丝合缝铺满 `mdat`）必须过。它不过时
  的症状和「密码学错了」一模一样，先修它再谈别的。
- **实现落在数据源这一层**（`CencDecryptDataSource` + Dart 侧编的「解密计划」）：Dart 只取
  流头部（`moov` 在那儿）解析出样本索引与等长替换补丁，Kotlin 按字节范围二分查样本、就地
  解密。任意字节位置都能从对应的 counter 块起算，所以**拖动进度条也是对的**——这正是它比
  「先下载整集再解」强的地方。真机上 `STATE_READY` 约 2.3 秒，不用等整集。
  算不出计划时才退回那条预下载路径（它也保留着，已离线验证过）。
- **跨语言传二进制格式，往返测试是必需的**。第一版编码器把样本记录里的 IV 漏写了、又在
  记录后面单独补了一次，每个样本多出 8 字节、后面全部顶歪；真机上表现为一个和编解码**毫无
  关系**的 `Invalid NAL length`，白查了两轮。`test/decrypt_plan_test.dart` 现在盯着它：
  编码后按对端那份布局自己解一遍，游标必须严丝合缝走到末尾。
