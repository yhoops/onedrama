---
status: superseded by ADR-0005
---

# 薄 Android 插件承载 ExoPlayer 与 CENC 密钥，控件全在 Flutter

> **本 ADR 已被 [ADR-0005](0005-client-side-cenc-decryption.md) 部分取代。**
> 仍然成立：Kotlin 侧只持有 ExoPlayer 与纹理、**零 Kotlin UI**，控件/手势/锁屏全在 Flutter 画。
> 已被推翻：密钥注入这一手段，以及下面那条「失败则只播明文」的回退——真机上已证实
> ExoPlayer 的提取器无法处理这段流，而 App 源正片全是加密的，只播明文等于片库为空。

App 取流从 `spade_a` 还原出的是一把 16 字节裸 AES-128 密钥，不是许可证服务器返回的密钥响应，官方 `video_player` 和 `media_kit` 都接不到这把钥匙；同时参考页的播放器 UI（右侧竖向控制栏、亮度/音量手势、锁屏、画质与倍速入口）也不是 ExoPlayer 自带控件能画出来的。所以 Kotlin 侧只做三件事——持有 ExoPlayer、注入 CENC 密钥、输出 Texture——不写任何 Kotlin UI，控件、手势、锁屏全部由 Flutter 绘制。

## Considered Options

- **原生 Activity + ExoPlayer 自带控件**：最省事，但只有底部横条控件，参考页的播放设计全做不到。
- **整页原生 Kotlin Activity**：最贴参考页，但 UI 要在 Kotlin 里再写一遍，主题、字体、转场与 Flutter 剧库彻底割裂。
- **明文走 `video_player`、加密另弹原生 Activity**：两套播放器，进度回传、自动连播、选集都要处理两遍。

## Consequences

密钥注入是唯一可能整块做不成的点，所以先做播放穿刺（真机、优先挑带 `CENCKey` 的集），穿刺通过后本 ADR 才生效。

穿刺若证伪，回退到**只播明文**：网页与备用源常是明文，加密集在详情页和选集上明确标注禁用并给出原因，不引入 FFmpeg 预解密（体积、耗电、上游维护状况都不划算）。
