# onedrama

A short-drama client. v1 talks only to 红果 (hongguo); the product is not a 红果 clone.

## Language

**Drama**:
A short-play series (一部短剧). Identified as `hongguo:{series_id}` while 红果 is the only source.
_Avoid_: 小说, book, series (alone), 作品

**Episode**:
One playable installment of a Drama (一集). Identified as `hongguo:{series_id}:{vid}`.
_Avoid_: Chapter, 章节, video (as the domain object)

**Source**:
An upstream catalog/player that can list Dramas and resolve Episode media. v1 has exactly one: 红果.
_Avoid_: provider, site, scraper (as the domain name)

**App Interface**:
红果 as reached through its signed app endpoints. Publishes Heat, View Count, the episode list, and stream keys. Publishes **no Rating**.
_Avoid_: App Source, App 源 (源 already means [Source]), native API

**Web Interface**:
红果 as reached through its public web pages. Publishes **Rating**, and needs no request signing. Publishes **no View Count**.
_Avoid_: Web Source, 网页源, H5, front-end

**Media**:
A concrete playable stream for an Episode: HTTP(S) URL, optional AES-128 CENC key, referer, and the frame's real pixel size. The Episode's `hongguo-cenc://{vid}` address is a placeholder, not Media.
_Avoid_: video URL, stream (alone), playback

**Quality Label**:
The stream's tier name as published by 红果 (360p / 480p / … / 1080p). It is **not** the frame's pixel height — some Dramas label a 1280×720 stream 「1080p」, and a portrait Drama's 「480p」 is 480 wide × 854 tall. Name a tier to the user with the label; lay out the picture with Media's real size.
_Avoid_: resolution, 分辨率, quality (alone)

**Heat**:
A Drama's popularity figure, published by 红果's App Interface. A different number from [View Count], and shown at a different precision — Heat as whole 万, View Count to one decimal.
_Avoid_: popularity, 播放量, score

**View Count**:
How many times a Drama has been watched, published by 红果's App Interface. Not [Heat], not [Rating]. The Web Interface never publishes it.
_Avoid_: 播放量 (ambiguous), Heat, views (alone)

**Rating**:
A Drama's viewer score (评分), e.g. 9.2. Published **only by 红果's Web Interface** — the App Interface has no such field, and many Dramas have no Rating at all. Its absence is normal, not a failure.
_Avoid_: score, 打分, star, 好评度

**Watch Progress**:
Local, per-Episode position and completion on this device. Not synced to 红果. Not an account.
_Avoid_: history (as the record itself), 观看记录 when meaning the Episode cursor

**Watch History**:
The ordered list of Episodes actually played on this device. Derived from Watch Progress.
_Avoid_: recently played, 播放记录, 观看记录 (when meaning the list)

**Favorite**:
A Drama kept for later, whether or not it was watched. Local to this device; not an account.
_Avoid_: 追剧, collection, watchlist, bookmark

**Ranking Board**:
A ranked list of Dramas published by 红果 for a period (总热播 / 真人 / 漫剧 / AI). Refreshes daily.
_Avoid_: chart, top list, 排行榜
