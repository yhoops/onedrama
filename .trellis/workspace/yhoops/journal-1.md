# Journal - yhoops (Part 1)

> AI development session journal
> Started: 2026-09-27

---



## Session 1: 题材筛选（服务端官方词表）+ 轻量筛选浮层
<!-- trellis-session: v=2 fp=052e6cfb78f25359 -->

**Date**: 2026-09-27
**Task**: 题材筛选（服务端官方词表）+ 轻量筛选浮层
**Branch**: `iter/tag-filter`

### Summary

取证推翻「红果没有题材词表接口」：题材数据只在网页接口（selectorList 24/8 项），服务端筛选是路径段 /category/<类型>/<题材>；App 分类行 tags 为空且不吐词表。用户从浏览器抓请求解锁。分类标签的题材 chip 升级成单选筛选器（综合保持跳搜索）；榜单旁加「筛选」浮层（题材服务端 / 状态篇幅·排序本地，applyLibraryFilters 纯函数）。CatalogPager 加 filterRoute（只走网页、不走 _webMode 降级）。补两处跨筛选 pager 身份竞态守卫；修浮层 chip 被 Container(alignment:) 撑满 Wrap 的布局 bug。analyze 干净；app 85 / 协议 46 全绿；LIVE drift 确认词表与上游一致；真机 adb 三标签筛选/排序/重置通过。用户报的「黑屏」复现三次未果，落为防御性修复并如实标注。

### Git Commits

| Hash | Message |
|------|---------|
| `5b41fe0` | feat: 题材筛选（服务端官方词表）+ 轻量筛选浮层 |

### Status

[OK] **Completed**
