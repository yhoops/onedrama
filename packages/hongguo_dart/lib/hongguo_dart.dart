/// 红果协议层。
///
/// 与 Go 包 `hongguo/` 一一对照：那边是协议真相，这里是 Dart 侧实现，
/// 两边靠共享 fixtures 双向比对防分叉（见 `docs/adr/0003`）。
///
/// 覆盖：签名、ID、CENC 密钥还原与**样本解密**、备用接口解密、网页解析、
/// 分类/推荐/榜单/搜索、三级取流。不碰 UI、不碰播放器。
///
/// 比 Go 多出来的只有 CENC 样本解密（`cenc.dart`）——Go 那边明确「只给密钥，
/// 不解封装」，而这边的播放器必须自己解（见 `docs/adr/0005`）。
library;

export 'src/catalog.dart'
    show
        AppGenre,
        CatalogCursor,
        CatalogPage,
        HongguoCatalogApi,
        RecommendationPage,
        RecommendationQuery,
        WebCategory,
        appGenres,
        appGenreWebRoutes,
        parseCatalogPage,
        webCategories,
        webRouteForGenre;
export 'src/cenc.dart'
    show
        BytePatch,
        CencIndex,
        CencSample,
        CencTrack,
        Mp4Box,
        aesCtrDecrypt,
        buildNeutralizingPatches,
        decryptToClearFile,
        freeBoxOfSize,
        mp4Child,
        mp4Children,
        mp4ChildrenOf,
        mp4ContainerTypes,
        mp4Descend,
        mp4Top,
        walkAvcc;
export 'src/client.dart'
    show
        HongguoClient,
        HongguoRequestException,
        appAid,
        appBaseUrl,
        appName,
        appUserAgent,
        appVersionCode,
        appVersionName,
        encodeQuery,
        flattenHeaders,
        maxBodyBytes,
        mediaReferer,
        playbackApiUrl,
        trimTrailingSlash,
        truncateText,
        webBaseUrl,
        webUserAgent;
export 'src/cover.dart' show coverAddress, coverPathFromAny, isValidImageUrl;
export 'src/crypto.dart'
    show
        HongguoProtocolException,
        contentKey,
        decodeBase64,
        decodePlaybackResponse,
        pkcs7Unpad;
export 'src/detail.dart'
    show
        HongguoDetailApi,
        SocialInfo,
        parseAppDetail,
        parseWebDetail,
        parseWebSocialInfo;
export 'src/ids.dart'
    show
        canonicalSource,
        dramaId,
        episodeId,
        hongguoSource,
        mediaPlaceholder,
        mediaScheme,
        numericIdPattern,
        splitDramaId,
        videoIdFromUrl;
export 'src/json.dart'
    show
        Drama,
        DramaDetail,
        Episode,
        anyList,
        decodeJsonObject,
        dramaFromAny,
        firstNonEmpty,
        mapString,
        mapStringSlice,
        mergeDrama,
        nestedMap,
        normalizeDate,
        releaseStatusFromRemark,
        subTitleLabels,
        timestampDate;
export 'src/media.dart'
    show
        HongguoMediaApi,
        Media,
        isHttpMediaUrl,
        mediaAddresses,
        qualityFromText,
        selectAppMedia;
export 'src/media_web.dart'
    show HongguoMediaTiersApi, parsePlaybackApi, parseWebMedia;
export 'src/rankings.dart'
    show
        HongguoRankingApi,
        RankingBoard,
        RankingItem,
        RankingPage,
        findRankingBoard,
        parseRanking,
        rankingBoards;
export 'src/search.dart'
    show
        HongguoSearchApi,
        SearchResult,
        Suggestion,
        SuggestionRecord,
        normalizeSearchKeyword,
        parseSearchPage,
        searchText,
        titleSearchRank;
export 'src/sign.dart' show newDeviceId, signRequest;
export 'src/sm3.dart' show sm3;
export 'src/web.dart'
    show
        catalogBlockReason,
        extractAttr,
        parseRouterData,
        routerLoaderMap,
        scriptTags,
        unescapeHtml;
