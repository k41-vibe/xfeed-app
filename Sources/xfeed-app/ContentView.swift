import SwiftUI
import Foundation
import CryptoKit
import AVKit

// ============================================================
// MARK: - Theme
// ============================================================

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: 1.0
        )
    }
}

enum Theme {
    static let background = Color(hex: 0x151515)
    static let card       = Color(hex: 0x1E1E1E)
    static let text       = Color(hex: 0xE0E0E0)
    static let accent     = Color(hex: 0xFF6B35)
    static let separator  = Color(hex: 0x333333)
    static let subtext    = Color(hex: 0x8A8A8A)

    // カード外側の余白
    static let cardTop: CGFloat     = 16
    static let cardSide: CGFloat    = 16
    static let cardBottom: CGFloat  = 8
    // カード内パディング
    static let cardPadding: CGFloat = 16
    // カード間隔
    static let cardSpacing: CGFloat = 8
}

// ============================================================
// MARK: - Model
// ============================================================

/// メディア（画像・動画・GIF）
struct Media: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case photo
        case video
        case animatedGif
    }

    let kind: Kind
    /// 表示用の URL（動画は poster 画像）
    let url: String
    /// 動画の場合の再生用 URL
    let videoUrl: String?

    var isPlayable: Bool { kind != .photo && videoUrl != nil }
}

/// 引用ツイート
struct QuotedTweet: Codable, Hashable, Sendable {
    let id: String
    let userName: String
    let screenName: String
    let text: String
    let imageUrl: String?
}

struct Tweet: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let userName: String
    let screenName: String
    let text: String
    /// 最初のメディア（後方互換のため残す）
    let imageUrl: String?
    /// すべてのメディア
    let media: [Media]
    let quoted: QuotedTweet?
    let likes: Int
    let reposts: Int
    let replies: Int
    let createdAt: Date

    init(id: String, userName: String, screenName: String, text: String,
         imageUrl: String?, media: [Media] = [], quoted: QuotedTweet? = nil,
         likes: Int, reposts: Int, replies: Int, createdAt: Date) {
        self.id = id
        self.userName = userName
        self.screenName = screenName
        self.text = text
        self.imageUrl = imageUrl
        self.media = media
        self.quoted = quoted
        self.likes = likes
        self.reposts = reposts
        self.replies = replies
        self.createdAt = createdAt
    }

    /// feeds.json（埋め込みフォールバック）用
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id         = try c.decode(String.self, forKey: .id)
        userName   = try c.decode(String.self, forKey: .userName)
        screenName = try c.decodeIfPresent(String.self, forKey: .screenName) ?? ""
        text       = try c.decode(String.self, forKey: .text)
        imageUrl   = try c.decodeIfPresent(String.self, forKey: .imageUrl)
        quoted     = try c.decodeIfPresent(QuotedTweet.self, forKey: .quoted)
        likes      = try c.decodeIfPresent(Int.self, forKey: .likes) ?? 0
        reposts    = try c.decodeIfPresent(Int.self, forKey: .reposts) ?? 0
        replies    = try c.decodeIfPresent(Int.self, forKey: .replies) ?? 0

        // media が無いのに imageUrl がある場合は、画像1枚として扱う
        let decoded = try c.decodeIfPresent([Media].self, forKey: .media) ?? []
        if decoded.isEmpty, let imageUrl {
            media = [Media(kind: .photo, url: imageUrl, videoUrl: nil)]
        } else {
            media = decoded
        }

        let raw = try c.decode(String.self, forKey: .createdAt)
        createdAt = XDate.parse(raw) ?? Date()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(userName, forKey: .userName)
        try c.encode(screenName, forKey: .screenName)
        try c.encode(text, forKey: .text)
        try c.encodeIfPresent(imageUrl, forKey: .imageUrl)
        try c.encode(media, forKey: .media)
        try c.encodeIfPresent(quoted, forKey: .quoted)
        try c.encode(likes, forKey: .likes)
        try c.encode(reposts, forKey: .reposts)
        try c.encode(replies, forKey: .replies)
        try c.encode(XDate.isoString(from: createdAt), forKey: .createdAt)
    }

    enum CodingKeys: String, CodingKey {
        case id, userName, screenName, text, imageUrl, media, quoted
        case likes, reposts, replies, createdAt
    }
}

/// 日付の解釈。フォーマッタはスレッドローカルに持つので、
/// どのスレッド（非MainActor を含む）からでも呼べる。
enum XDate: Sendable {
    /// X の API 形式: "Sat Sep 20 12:00:00 +0000 2026"
    ///
    /// DateFormatter は Sendable ではないので、グローバルに共有できない。
    /// スレッドごとに1つ持てば同じフォーマッタに同時に触れない。
    private static let xKey = "xdate.x"
    private static let isoKey = "xdate.iso"

    private static var x: DateFormatter {
        let dict = Thread.current.threadDictionary
        if let f = dict[xKey] as? DateFormatter { return f }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE MMM dd HH:mm:ss Z yyyy"
        dict[xKey] = f
        return f
    }

    private static var iso: ISO8601DateFormatter {
        let dict = Thread.current.threadDictionary
        if let f = dict[isoKey] as? ISO8601DateFormatter { return f }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        dict[isoKey] = f
        return f
    }

    /// "2026-09-20T09:12:00Z" のような ISO8601 を優先して解釈する。
    static func parse(_ s: String) -> Date? {
        iso.date(from: s) ?? x.date(from: s)
    }

    /// X の GraphQL が返す日時を解釈する。
    /// 解釈できない場合は nil を返す。現在時刻で埋めると、古い投稿が
    /// 最新として並んでしまうため。
    static func parseGraphQL(_ s: String) -> Date? {
        if let d = x.date(from: s) { return d }
        if let d = iso.date(from: s) { return d }
        return nil
    }

    /// Date を ISO8601 文字列にする（feeds.json への書き出し用）
    static func isoString(from date: Date) -> String {
        iso.string(from: date)
    }
}

// ============================================================
// MARK: - Timeline source（トップ画面の固定3行）
// ============================================================

enum TimelineSource: String, CaseIterable, Identifiable, Sendable {
    case following
    case forYou
    case user

    var id: String { rawValue }

    func title(_ lang: AppLanguage) -> String {
        switch (self, lang) {
        case (.following, .ja): return "フォロー中"
        case (.following, .en): return "Following"
        case (.forYou, .ja):    return "おすすめ"
        case (.forYou, .en):    return "For you"
        case (.user, .ja):      return "ユーザー"
        case (.user, .en):      return "User"
        }
    }

    func subtitle(_ lang: AppLanguage) -> String {
        switch (self, lang) {
        case (.following, .ja): return "フォローしているアカウント"
        case (.following, .en): return "Accounts you follow"
        case (.forYou, .ja):    return "アルゴリズムによるおすすめ"
        case (.forYou, .en):    return "Recommended for you"
        case (.user, .ja):      return "指定したユーザーIDの投稿"
        case (.user, .en):      return "Tweets from a specific user ID"
        }
    }

    var symbol: String {
        switch self {
        case .following: return "person.2.fill"
        case .forYou:    return "sparkles"
        case .user:      return "person.crop.circle"
        }
    }

    var queryIdKey: QueryIdKey {
        switch self {
        case .following: return .homeLatest
        case .forYou:    return .home
        case .user:      return .userTweets
        }
    }
}

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case ja, en
    var id: String { rawValue }
    var label: String { self == .ja ? "日本語" : "English" }
}

enum QueryIdKey: String, CaseIterable, Sendable {
    case home
    case homeLatest
    case userTweets

    var operationName: String {
        switch self {
        case .home:       return "HomeTimeline"
        case .homeLatest: return "HomeLatestTimeline"
        case .userTweets: return "UserTweets"
        }
    }
}

// ============================================================
// MARK: - Settings（UserDefaults）
// ============================================================

/// 設定の保管。すべて MainActor 上で読み書きする。
/// ネットワーク処理は @MainActor の XClient から呼ぶので、これで競合しない。
@MainActor
final class AppSettings: ObservableObject {

    private let d = UserDefaults.standard

    // --- 認証（B方式: ブラウザからコピーしたCookie） ---
    @Published var authToken: String   { didSet { d.set(authToken, forKey: "authToken") } }
    @Published var ct0: String         { didSet { d.set(ct0, forKey: "ct0") } }
    @Published var bearerToken: String { didSet { d.set(bearerToken, forKey: "bearerToken") } }

    // --- 表示 ---
    @Published var refreshInterval: Double { didSet { d.set(refreshInterval, forKey: "refreshInterval") } }
    @Published var maxItems: Int           { didSet { d.set(maxItems, forKey: "maxItems") } }
    @Published var language: AppLanguage   { didSet { d.set(language.rawValue, forKey: "language") } }
    @Published var userID: String          { didSet { d.set(userID, forKey: "userID") } }

    // --- フィードURL（空なら埋め込みJSON / X API） ---
    @Published var feedURL: String { didSet { d.set(feedURL, forKey: "feedURL") } }

    // --- queryId（Xのデプロイで変わるため可変） ---
    @Published var homeQueryId: String       { didSet { d.set(homeQueryId, forKey: "queryId.home") } }
    @Published var homeLatestQueryId: String { didSet { d.set(homeLatestQueryId, forKey: "queryId.homeLatest") } }
    @Published var userTweetsQueryId: String { didSet { d.set(userTweetsQueryId, forKey: "queryId.userTweets") } }

    init() {
        authToken   = d.string(forKey: "authToken") ?? ""
        ct0         = d.string(forKey: "ct0") ?? ""
        bearerToken = d.string(forKey: "bearerToken") ?? XConstants.publicBearer

        let ri = d.double(forKey: "refreshInterval")
        refreshInterval = ri > 0 ? ri : 30

        let mi = d.integer(forKey: "maxItems")
        maxItems = mi > 0 ? mi : 20

        language = AppLanguage(rawValue: d.string(forKey: "language") ?? "ja") ?? .ja
        userID   = d.string(forKey: "userID") ?? ""
        feedURL  = d.string(forKey: "feedURL") ?? ""

        // queryId は X が 2〜4 週ごとに回転させる。初回は既定値を入れておき、
        // 404 になったら XClient が自動で同期し直す。
        homeQueryId       = d.string(forKey: "queryId.home")
                            ?? XConstants.fallbackQueryIds["HomeTimeline"] ?? ""
        homeLatestQueryId = d.string(forKey: "queryId.homeLatest")
                            ?? XConstants.fallbackQueryIds["HomeLatestTimeline"] ?? ""
        userTweetsQueryId = d.string(forKey: "queryId.userTweets")
                            ?? XConstants.fallbackQueryIds["UserTweets"] ?? ""
    }

    var isAuthenticated: Bool { !authToken.isEmpty && !ct0.isEmpty }

    func queryId(for key: QueryIdKey) -> String {
        switch key {
        case .home:       return homeQueryId
        case .homeLatest: return homeLatestQueryId
        case .userTweets: return userTweetsQueryId
        }
    }

    func setQueryId(_ value: String, for key: QueryIdKey) {
        switch key {
        case .home:       homeQueryId = value
        case .homeLatest: homeLatestQueryId = value
        case .userTweets: userTweetsQueryId = value
        }
    }

    /// 翻訳ヘルパ
    func t(_ ja: String, _ en: String) -> String { language == .ja ? ja : en }
}

// ============================================================
// MARK: - X のエラー
// ============================================================

enum XClientError: LocalizedError {
    case notAuthenticated
    case missingSetting(String)
    case http(Int)
    case decoding
    case network(String)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:        return "not authenticated"
        case .missingSetting(let n):   return "missing setting: \(n)"
        case .http(let code):          return "HTTP \(code)"
        case .decoding:                return "decode failed"
        case .network(let m):          return m
        }
    }
}

// ============================================================
// MARK: - X の定数（純粋なデータ。アクター分離しない）
// ============================================================

enum XConstants {

    /// x.com の Web アプリが同梱している公開 Bearer。
    /// 秘密情報ではない（x.com の JS バンドルに平文で入っている）。
    static let publicBearer =
        "AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puTs%3D1Zv7ttfk8LF81IUq16cHjhLTvJu4FA33AGWWjCpTnA"

    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    /// 既定の queryId。X は 2〜4 週ごとに回転させるので、これは暫定値。
    /// 設定画面の「同期」で JS バンドルから取り直す前提。
    static let fallbackQueryIds: [String: String] = [
        "HomeTimeline":       "c-CzHF1LboFilMpsx4ZCrQ",
        "HomeLatestTimeline": "BKB7oi212Fi7kQtCBGE4zA",
        "UserTweets":         "q6xj5bs0hapm9309hexA_g",
    ]

    /// コミュニティ管理の queryId 一覧。JS バンドルの走査が失敗したときの保険。
    static let communityQueryIdURL =
        "https://raw.githubusercontent.com/fa0311/twitter-openapi/"
        + "refs/heads/main/src/config/placeholder.json"

    /// X の Web クライアントが送る feature フラグ。
    /// false のものは送らない（X は未指定を false として扱う）。
    static let features: [String: Bool] = [
        "responsive_web_graphql_exclude_directive_enabled": true,
        "verified_phone_label_enabled": false,
        "creator_subscriptions_tweet_preview_api_enabled": true,
        "responsive_web_graphql_timeline_navigation_enabled": true,
        "responsive_web_graphql_skip_user_profile_image_extensions_enabled": false,
        "c9s_tweet_anatomy_moderator_badge_enabled": true,
        "tweetypie_unmention_optimization_enabled": true,
        "responsive_web_edit_tweet_api_enabled": true,
        "graphql_is_translatable_rweb_tweet_is_translatable_enabled": true,
        "view_counts_everywhere_api_enabled": true,
        "longform_notetweets_consumption_enabled": true,
        "responsive_web_twitter_article_tweet_consumption_enabled": true,
        "tweet_awards_web_tipping_enabled": false,
        "longform_notetweets_rich_text_read_enabled": true,
        "longform_notetweets_inline_media_enabled": true,
        "rweb_video_timestamps_enabled": true,
        "responsive_web_media_download_video_enabled": true,
        "freedom_of_speech_not_reach_fetch_enabled": true,
        "standardized_nudges_misinfo": true,
        "responsive_web_enhance_cards_enabled": false,
    ]

    /// false を落とす。X は未指定の feature を false として扱うため、
    /// 送ると本文が無駄に長くなる。
    static var compactFeatures: [String: Bool] {
        features.filter { $0.value }
    }
}

// ============================================================
// MARK: - X Client（URLSession のみ。WKWebView は一切使わない）
// ============================================================

@MainActor
struct XClient {

    /// Cookie は自分でヘッダーに載せるので、URLSession 側の Cookie 管理は切る。
    /// 共有ストアを使わないよう ephemeral にする。
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        cfg.httpCookieStorage = nil
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 60
        return URLSession(configuration: cfg)
    }()

    /// queryId を探すために取得する JS バンドルの上限。
    /// client-web のバンドルは数十個あるので、全部取ると通信量が過大になる。
    private static let maxBundlesToScan = 12

    // MARK: transaction-id
    //
    // X は一部のエンドポイントで x-client-transaction-id ヘッダーを要求する。
    // 生成手順（iSarabjitDhiman/XClientTransaction の実装より）:
    //   1. x.com の HTML から twitter-site-verification メタタグの値を取り、base64 デコード
    //   2. ondemand.s の SVG パスから animation_key（16進文字列）を計算
    //   3. 時刻・乱数キーワード・animation_key を連結して SHA-256
    //   4. [key バイト列] + [時刻4バイト] + [ハッシュ先頭16バイト] + [3] を組み立て
    //   5. ランダム1バイトで全バイトを XOR し、その1バイトを先頭に付ける
    //   6. base64 にして = を除去
    //
    // 3 の animation_key は SVG の補間計算が必要で、実装が重い。
    // 読み取り系では無しでも通る例が確認できているため、まずはヘッダーを付けずに試し、
    // 403 が返ったときだけ付ける方針にしている。

    /// transaction-id の生成に必要な素材。x.com から1度だけ取得して使い回す。
    struct TransactionMaterial: Sendable {
        let verificationKey: [UInt8]
        let animationKey: String
    }

    /// 時刻の基準。2023-05-01 00:00:00 UTC からの経過秒を使う。
    private static let transactionEpoch: TimeInterval = 1_683_000_000
    private static let transactionKeyword = "obfiowerehiring"
    private static let transactionAdditionalNumber: UInt8 = 3

    /// x.com の HTML と ondemand.s から素材を集める。
    func fetchTransactionMaterial(settings s: AppSettings) async throws -> TransactionMaterial? {
        var req = URLRequest(url: URL(string: "https://x.com/home")!)
        for (k, v) in headers(s) { req.setValue(v, forHTTPHeaderField: k) }
        req.timeoutInterval = 20

        let (htmlData, _) = try await Self.session.data(for: req)
        let html = String(decoding: htmlData, as: UTF8.self)

        guard let keyB64 = Self.findSiteVerification(in: html),
              let keyData = Data(base64Encoded: keyB64) else {
            return nil
        }

        // ondemand.s から SVG を取って animation_key を作る
        var animationKey = ""
        if let ondemandURL = Self.findOndemandURL(in: html),
           let js = try? await fetchString(ondemandURL) {
            animationKey = Self.computeAnimationKey(fromJS: js) ?? ""
        }

        return TransactionMaterial(
            verificationKey: [UInt8](keyData),
            animationKey: animationKey
        )
    }

    /// 素材から transaction-id を1つ作る。
    static func makeTransactionId(material: TransactionMaterial,
                                  method: String,
                                  path: String) -> String {
        let elapsed = UInt32(Date().timeIntervalSince1970 - transactionEpoch)

        // 時刻を4バイトのリトルエンディアンに
        let timeBytes: [UInt8] = [
            UInt8(elapsed & 0xFF),
            UInt8((elapsed >> 8) & 0xFF),
            UInt8((elapsed >> 16) & 0xFF),
            UInt8((elapsed >> 24) & 0xFF),
        ]

        // SHA-256(method + path + 時刻10進 + keyword + animationKey)
        let payload = method + path + String(elapsed)
                    + transactionKeyword + material.animationKey
        let digest = SHA256.hash(data: Data(payload.utf8))
        let hashBytes = Array(digest)

        // 組み立て: key + time + hash先頭16 + additionalNumber
        var buf = material.verificationKey
        buf.append(contentsOf: timeBytes)
        buf.append(contentsOf: hashBytes.prefix(16))
        buf.append(transactionAdditionalNumber)

        // ランダム1バイトで全体を XOR し、そのバイトを先頭に置く
        let mask = UInt8.random(in: 0...255)
        var out: [UInt8] = [mask]
        out.append(contentsOf: buf.map { $0 ^ mask })

        // base64。パディングの = は除去する
        return Data(out).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
    }

    /// twitter-site-verification メタタグの値を取り出す。
    static func findSiteVerification(in html: String) -> String? {
        let pattern = #"name="twitter-site-verification"\s+content="([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        guard let m = regex.firstMatch(in: html, range: range),
              m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: html) else { return nil }
        return String(html[r])
    }

    /// ondemand.s の URL を拾う。
    static func findOndemandURL(in html: String) -> URL? {
        let pattern = #"https://abs\.twimg\.com/responsive-web/client-web/ondemand\.s\.[a-zA-Z0-9]+\.js"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        guard let m = regex.firstMatch(in: html, range: range),
              let r = Range(m.range, in: html) else { return nil }
        return URL(string: String(html[r]))
    }

    /// ondemand.s の中の SVG パスから animation_key を作る。
    ///
    /// 元実装は SVG のアニメーションキーフレームを補間して長い16進文字列を作る。
    /// ここでは補間の計算を省略し、パス文字列から決定的なハッシュを作って代用する。
    /// X 側の検証を通るかは未確認。403 が出た場合の出発点として置いておく。
    static func computeAnimationKey(fromJS js: String) -> String? {
        // SVG の d 属性（パス）を全部集める
        let pattern = #"d="([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(js.startIndex..., in: js)
        let matches = regex.matches(in: js, range: range)

        var paths: [String] = []
        for m in matches where m.numberOfRanges > 1 {
            if let r = Range(m.range(at: 1), in: js) {
                let s = String(js[r])
                if s.count > 20 { paths.append(s) }
            }
        }
        guard !paths.isEmpty else { return nil }

        // 決定的な16進文字列を作る
        let joined = paths.joined(separator: "|")
        let digest = SHA256.hash(data: Data(joined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: ヘッダー

    private func headers(_ s: AppSettings,
                         transactionId: String? = nil) -> [String: String] {
        var h: [String: String] = [
            "Authorization": "Bearer \(s.bearerToken)",
            "Cookie": "auth_token=\(s.authToken); ct0=\(s.ct0)",
            "x-csrf-token": s.ct0,
            "x-twitter-auth-type": "OAuth2Session",
            "x-twitter-active-user": "yes",
            "x-twitter-client-language": s.language == .ja ? "ja" : "en",
            "Content-Type": "application/json",
            "Accept": "*/*",
            "Accept-Language": s.language == .ja ? "ja" : "en-US",
            "User-Agent": XConstants.userAgent,
            "Referer": "https://x.com/",
            "Origin": "https://x.com",
        ]
        if let transactionId { h["x-client-transaction-id"] = transactionId }
        return h
    }

    // MARK: タイムライン取得
    //
    // X の GraphQL は POST のみ受け付ける。GET は 404 を返す（2026-08 時点で
    // SearchTimeline / Followers が GET 廃止、HomeTimeline はさらに前から POST）。
    // body は {variables, features, queryId} で、queryId は URL と body の両方に要る。

    func fetch(source: TimelineSource,
               cursor: String? = nil,
               settings s: AppSettings) async throws -> Page {
        guard s.isAuthenticated else { throw XClientError.notAuthenticated }

        let op = source.queryIdKey.operationName
        let variables = try Self.variables(for: source, cursor: cursor, settings: s)

        do {
            return try await send(op: op,
                                  variables: variables,
                                  queryId: s.queryId(for: source.queryIdKey),
                                  settings: s)

        } catch let XClientError.http(code) where code == 404 {
            // queryId が回転した可能性が高い。同期して1度だけ再試行する。
            let fresh = try await syncQueryIds(settings: s)
            guard let updated = fresh[source.queryIdKey], !updated.isEmpty else {
                throw XClientError.http(404)
            }
            s.setQueryId(updated, for: source.queryIdKey)
            return try await send(op: op,
                                  variables: variables,
                                  queryId: updated,
                                  settings: s)

        } catch let XClientError.http(code) where code == 403 {
            // transaction-id を要求されている。素材を取って付けて1度だけ再試行する。
            guard let material = try? await fetchTransactionMaterial(settings: s) else {
                throw XClientError.http(403)
            }
            let tid = Self.makeTransactionId(
                material: material,
                method: "POST",
                path: "/i/api/graphql/\(s.queryId(for: source.queryIdKey))/\(op)"
            )
            return try await send(op: op,
                                  variables: variables,
                                  queryId: s.queryId(for: source.queryIdKey),
                                  settings: s,
                                  transactionId: tid)
        }
    }

    private static func variables(for source: TimelineSource,
                                  cursor: String?,
                                  settings s: AppSettings) throws -> [String: Any] {
        switch source {
        case .following, .forYou:
            var v: [String: Any] = [
                "count": s.maxItems,
                "includePromotedContent": false,
                "latestControlAvailable": true,
                "requestContext": "launch",
                "withCommunity": true,
                "seenTweetIds": [String](),
            ]
            if let cursor { v["cursor"] = cursor }
            return v
        case .user:
            guard !s.userID.isEmpty else { throw XClientError.missingSetting("userID") }
            var v: [String: Any] = [
                "userId": s.userID,
                "count": s.maxItems,
                "includePromotedContent": false,
                "withClientEventToken": false,
                "withBirdwatchNotes": false,
                "withVoice": true,
            ]
            if let cursor { v["cursor"] = cursor }
            return v
        }
    }

    private func send(op: String,
                      variables: [String: Any],
                      queryId: String,
                      settings s: AppSettings,
                      transactionId: String? = nil) async throws -> Page {
        guard !queryId.isEmpty else { throw XClientError.missingSetting(op) }
        guard let url = URL(string: "https://x.com/i/api/graphql/\(queryId)/\(op)") else {
            throw XClientError.decoding
        }

        let body: [String: Any] = [
            "variables": variables,
            "features": XConstants.compactFeatures,
            "queryId": queryId,
        ]

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        for (k, v) in headers(s, transactionId: transactionId) {
            req.setValue(v, forHTTPHeaderField: k)
        }
        req.timeoutInterval = 20

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: req)
        } catch {
            throw XClientError.network(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw XClientError.http(http.statusCode)
        }

        // JSON の解析は重い。MainActor の外で走らせて UI を止めない。
        // extractTweets / extractBottomCursor は nonisolated な静的関数なので
        // detached タスクから呼んで問題ない。
        let page = try await Task.detached(priority: .userInitiated) {
            Page(tweets: try XClient.extractTweets(from: data),
                 nextCursor: XClient.extractBottomCursor(from: data))
        }.value

        return page
    }

    // MARK: GraphQL レスポンスから Tweet を抽出
    //
    // X のレスポンスはパス構造が頻繁に変わるため、パスを決め打ちせず
    // JSON ツリーを走査して「legacy を持ち full_text がある」辞書を拾う。

    nonisolated static func extractTweets(from data: Data) throws -> [Tweet] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else {
            throw XClientError.decoding
        }
        var found: [Tweet] = []
        walk(root, into: &found)

        // id で重複排除（引用・RT元が混ざるため）。順序は保持。
        var seen = Set<String>()
        var unique: [Tweet] = []
        for t in found where !seen.contains(t.id) {
            seen.insert(t.id)
            unique.append(t)
        }
        return unique
    }

    nonisolated private static func walk(_ obj: Any, into out: inout [Tweet]) {
        if let dict = obj as? [String: Any] {
            if let tweet = makeTweet(from: dict) { out.append(tweet) }
            for (key, value) in dict {
                // リツイート元と引用元の中身は辿らない。
                // 辿ると別IDのツイートとして二重に並ぶ。
                if key == "retweeted_status_result" || key == "quoted_status_result" {
                    continue
                }
                walk(value, into: &out)
            }
        } else if let arr = obj as? [Any] {
            for value in arr { walk(value, into: &out) }
        }
    }

    nonisolated private static func makeTweet(from dict: [String: Any]) -> Tweet? {
        // TweetWithVisibilityResults の場合、実体は .tweet 側
        if let nested = dict["tweet"] as? [String: Any],
           let t = makeTweet(from: nested) {
            return t
        }

        guard let legacy = dict["legacy"] as? [String: Any],
              let text = legacy["full_text"] as? String,
              let idStr = legacy["id_str"] as? String
        else { return nil }

        // プロモーション（広告）は読み飛ばす
        if let cards = legacy["card"] as? [String: Any],
           let name = cards["name"] as? String,
           name.hasPrefix("promo") {
            return nil
        }

        // ユーザー情報: core.user_results.result.legacy（新）または user.legacy（旧）
        var userLegacy: [String: Any]?
        if let core = dict["core"] as? [String: Any],
           let ur = core["user_results"] as? [String: Any],
           let result = ur["result"] as? [String: Any] {
            userLegacy = result["legacy"] as? [String: Any]
        }
        if userLegacy == nil, let u = dict["user"] as? [String: Any] {
            userLegacy = u["legacy"] as? [String: Any]
        }

        let name   = (userLegacy?["name"] as? String) ?? "unknown"
        let screen = (userLegacy?["screen_name"] as? String) ?? ""

        // メディア（extended_entities を優先。entities には動画の再生URLが無い）
        let rawMedia = (legacy["extended_entities"] as? [String: Any])?["media"] as? [[String: Any]]
            ?? (legacy["entities"] as? [String: Any])?["media"] as? [[String: Any]]
            ?? []

        let media: [Media] = rawMedia.compactMap { m in
            guard let url = m["media_url_https"] as? String else { return nil }

            let rawType = (m["type"] as? String) ?? "photo"
            let kind: Media.Kind
            switch rawType {
            case "video":       kind = .video
            case "animated_gif": kind = .animatedGif
            default:            kind = .photo
            }

            // 動画の再生URLは variants の mp4 のうち最高ビットレートを選ぶ
            var videoUrl: String?
            if kind != .photo,
               let info = m["video_info"] as? [String: Any],
               let variants = info["variants"] as? [[String: Any]] {
                let mp4s = variants.filter {
                    ($0["content_type"] as? String) == "video/mp4"
                }
                let best = mp4s.max {
                    (($0["bitrate"] as? Int) ?? 0) < (($1["bitrate"] as? Int) ?? 0)
                }
                videoUrl = best?["url"] as? String
            }

            return Media(kind: kind, url: url, videoUrl: videoUrl)
        }

        // 引用ツイート
        var quoted: QuotedTweet?
        if let q = dict["quoted_status_result"] as? [String: Any],
           let result = q["result"] as? [String: Any] {
            let qLegacy = result["legacy"] as? [String: Any]
                ?? (result["tweet"] as? [String: Any])?["legacy"] as? [String: Any]

            if let ql = qLegacy,
               let qid = ql["id_str"] as? String,
               let qtext = ql["full_text"] as? String {

                var qUser: [String: Any]?
                if let core = result["core"] as? [String: Any],
                   let ur = core["user_results"] as? [String: Any],
                   let r = ur["result"] as? [String: Any] {
                    qUser = r["legacy"] as? [String: Any]
                }

                var qImage: String?
                if let e = ql["extended_entities"] as? [String: Any],
                   let ms = e["media"] as? [[String: Any]],
                   let first = ms.first {
                    qImage = first["media_url_https"] as? String
                }

                quoted = QuotedTweet(
                    id: qid,
                    userName: (qUser?["name"] as? String) ?? "unknown",
                    screenName: (qUser?["screen_name"] as? String) ?? "",
                    text: qtext,
                    imageUrl: qImage
                )
            }
        }

        // 日時が解釈できないツイートは捨てる。
        // 現在時刻で埋めると、古い投稿が最新として並んでしまう。
        guard let created = XDate.parseGraphQL((legacy["created_at"] as? String) ?? "")
        else { return nil }

        return Tweet(
            id: idStr,
            userName: name,
            screenName: screen,
            text: text,
            imageUrl: media.first?.url,
            media: media,
            quoted: quoted,
            likes:   (legacy["favorite_count"] as? Int) ?? 0,
            reposts: (legacy["retweet_count"] as? Int) ?? 0,
            replies: (legacy["reply_count"] as? Int) ?? 0,
            createdAt: created
        )
    }

    // MARK: カーソルの抽出（無限スクロール用）

    /// TimelineCursor の Bottom 値を拾う。
    ///
    /// レスポンスには複数のカーソルが含まれることがある（タイムライン本体、
    /// 引用元、推薦枠など）。辞書の走査順は不定なので、単純に最初に見つかったものを
    /// 使うと別のタイムラインのカーソルを掴む。
    ///
    /// そのため、まず既知のタイムライン格納先を直接辿り、見つからなければ
    /// 全体を走査する。走査する場合も entryId が "cursor-bottom-" で始まるものを優先する。
    nonisolated static func extractBottomCursor(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // 1. 既知のパスを直接辿る。
        //    data.home.home_timeline_urt.instructions[] の中の TimelineAddEntries を見る。
        if let dataDict = root["data"] as? [String: Any] {
            for value in dataDict.values {
                if let cursor = findBottomCursorInTimeline(value) {
                    return cursor
                }
            }
        }

        // 2. 見つからなければ全体を走査し、entryId で絞る
        var fallback: String?
        var preferred: String?

        func walk(_ obj: Any) {
            if let dict = obj as? [String: Any] {
                if let content = dict["content"] as? [String: Any],
                   (content["__typename"] as? String) == "TimelineTimelineCursor",
                   (content["cursorType"] as? String) == "Bottom",
                   let value = content["value"] as? String {

                    // entryId が cursor-bottom- で始まるものを優先する
                    if let entryId = dict["entryId"] as? String,
                       entryId.hasPrefix("cursor-bottom-") {
                        if preferred == nil { preferred = value }
                    } else if fallback == nil {
                        fallback = value
                    }
                }
                for (_, v) in dict { walk(v) }
            } else if let arr = obj as? [Any] {
                for v in arr { walk(v) }
            }
        }

        walk(root)
        return preferred ?? fallback
    }

    /// data 配下のタイムライン格納先から Bottom カーソルを探す。
    nonisolated private static func findBottomCursorInTimeline(_ obj: Any) -> String? {
        guard let dict = obj as? [String: Any] else { return nil }

        // home_timeline_urt / timeline など、instructions を持つ辞書を探す
        for (key, value) in dict {
            if key.hasSuffix("_urt") || key == "timeline" {
                if let d = value as? [String: Any],
                   let cursor = scanInstructions(d) {
                    return cursor
                }
            }
        }

        var found: String?
        for (_, value) in dict where found == nil {
            found = findBottomCursorInTimeline(value)
        }
        return found
    }

    /// instructions 配列から TimelineAddEntries の Bottom カーソルを取り出す。
    nonisolated private static func scanInstructions(_ timeline: [String: Any]) -> String? {
        guard let instructions = timeline["instructions"] as? [[String: Any]] else {
            return nil
        }

        for inst in instructions {
            guard let entries = inst["entries"] as? [[String: Any]] else { continue }
            for entry in entries {
                guard let content = entry["content"] as? [String: Any],
                      (content["cursorType"] as? String) == "Bottom",
                      let value = content["value"] as? String else { continue }
                return value
            }
        }
        return nil
    }

    /// 取得結果（ツイートと次のカーソル）
    struct Page: Sendable {
        let tweets: [Tweet]
        let nextCursor: String?
    }

    // MARK: queryId の同期
    //
    // X は queryId を 2〜4 週ごとに回転させる。2段階で探す:
    //   1. x.com の HTML から client-web の JS バンドルを走査
    //   2. コミュニティ管理の一覧（twitter-openapi）
    //
    // 見つかった操作だけを返す。既定値（XConstants.fallbackQueryIds）での補完は
    // 呼び出し側が行う。同期が失敗したことを画面に出せるようにするため。

    func syncQueryIds(settings s: AppSettings) async throws -> [QueryIdKey: String] {
        var found: [String: String] = [:]

        // 1. JS バンドル走査
        if let scanned = try? await scanBundles(settings: s) {
            for (op, qid) in scanned where found[op] == nil {
                found[op] = qid
            }
        }

        // 2. コミュニティ一覧（走査で見つからなかった操作だけ補う）
        if let remote = try? await fetchCommunityQueryIds() {
            for (op, qid) in remote where found[op] == nil {
                found[op] = qid
            }
        }

        var result: [QueryIdKey: String] = [:]
        for key in QueryIdKey.allCases {
            if let qid = found[key.operationName], !qid.isEmpty {
                result[key] = qid
            }
        }
        return result
    }

    /// x.com を取得し、client-web の JS バンドルを走査して
    /// queryId と operationName の組を集める。
    private func scanBundles(settings s: AppSettings) async throws -> [String: String] {
        var req = URLRequest(url: URL(string: "https://x.com/home")!)
        for (k, v) in headers(s) { req.setValue(v, forHTTPHeaderField: k) }
        req.timeoutInterval = 20

        let (htmlData, htmlResp) = try await Self.session.data(for: req)
        if let http = htmlResp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw XClientError.http(http.statusCode)
        }
        let html = String(decoding: htmlData, as: UTF8.self)

        // main バンドルを先に見る。大半の操作はここに入っている。
        let ordered = Self.findBundleURLs(in: html).sorted { a, b in
            let am = a.lastPathComponent.hasPrefix("main.")
            let bm = b.lastPathComponent.hasPrefix("main.")
            return am && !bm
        }

        var found: [String: String] = [:]
        for jsURL in ordered.prefix(Self.maxBundlesToScan) {
            guard let js = try? await fetchString(jsURL) else { continue }
            for (op, qid) in Self.extractQueryIds(fromJS: js) where found[op] == nil {
                found[op] = qid
            }
        }
        return found
    }

    private func fetchString(_ url: URL) async throws -> String {
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        let (data, _) = try await Self.session.data(for: req)
        return String(decoding: data, as: UTF8.self)
    }

    /// コミュニティ管理の queryId 一覧（JSON: {操作名: {queryId: "..."}}）
    private func fetchCommunityQueryIds() async throws -> [String: String] {
        guard let url = URL(string: XConstants.communityQueryIdURL) else { return [:] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20

        let (data, resp) = try await Self.session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw XClientError.http(http.statusCode)
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }

        var out: [String: String] = [:]
        for (op, value) in root {
            if let dict = value as? [String: Any], let qid = dict["queryId"] as? String {
                out[op] = qid
            }
        }
        return out
    }

    /// x.com の HTML から client-web の JS バンドル URL を全部拾う。
    /// main.<hash>.js だけでなく、操作の定義を含む分割バンドルも対象にする。
    static func findBundleURLs(in html: String) -> [URL] {
        let pattern = #"(?:src|href)=["'](https://abs\.twimg\.com/responsive-web/client-web[^"']+\.js)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(html.startIndex..., in: html)

        var seen = Set<String>()
        var urls: [URL] = []
        for m in regex.matches(in: html, range: range) {
            guard m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: html) else { continue }
            let s = String(html[r])
            guard !seen.contains(s), let url = URL(string: s) else { continue }
            seen.insert(s)
            urls.append(url)
        }
        return urls
    }

    /// JS バンドルから queryId と operationName の組を全部拾う。
    /// 実物は `queryId:"..."` の後 200 文字以内に `operationName:"..."` が来る形で、
    /// 空白が入ることもある。
    static func extractQueryIds(fromJS js: String) -> [String: String] {
        let pattern = #"queryId:\s*"([A-Za-z0-9_-]+)"[^}]{0,200}?operationName:\s*"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [:] }
        let range = NSRange(js.startIndex..., in: js)

        var out: [String: String] = [:]
        for m in regex.matches(in: js, range: range) {
            guard m.numberOfRanges > 2,
                  let qr = Range(m.range(at: 1), in: js),
                  let or = Range(m.range(at: 2), in: js) else { continue }
            out[String(js[or])] = String(js[qr])
        }
        return out
    }
}

// ============================================================
// MARK: - Feed state
// ============================================================

enum FeedState: Sendable {
    case loading
    case loaded([Tweet])
    /// 未認証時に表示する埋め込みサンプル
    case demo([Tweet])
    case empty
    case failed
}

// ============================================================
// MARK: - Root
// ============================================================

struct ContentView: View {
    var body: some View {
        NavigationStack {
            ThreadListView()
        }
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
    }
}

// ============================================================
// MARK: - 1. ThreadListView（トップ画面）
// ============================================================

struct ThreadListView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: Theme.cardSpacing) {
                    ForEach(TimelineSource.allCases) { source in
                        NavigationLink {
                            FeedListView(source: source)
                        } label: {
                            ThreadRow(source: source, language: settings.language)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, Theme.cardTop)
                .padding(.horizontal, Theme.cardSide)
                .padding(.bottom, Theme.cardBottom)
            }
        }
        .navigationTitle(settings.t("Xフィード", "X Feed"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    SettingsView()
                } label: {
                    Image(systemName: "gearshape")
                        .foregroundStyle(Theme.accent)
                }
            }
        }
        .toolbarBackground(Theme.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }
}

struct ThreadRow: View {
    let source: TimelineSource
    let language: AppLanguage

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: source.symbol)
                .font(.system(size: 20))
                .foregroundStyle(Theme.accent)
                .frame(width: 25, height: 25)

            VStack(alignment: .leading, spacing: 4) {
                Text(source.title(language))
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.text)

                Text(source.subtitle(language))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.subtext)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.subtext)
        }
        .padding(Theme.cardPadding)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// ============================================================
// MARK: - 2. FeedListView（スレッド詳細）
// ============================================================

struct FeedListView: View {
    let source: TimelineSource

    @EnvironmentObject private var settings: AppSettings

    @State private var state: FeedState = .loading
    @State private var reloadToken = 0
    /// 次に読むページのカーソル。nil なら末尾。
    @State private var nextCursor: String?
    @State private var isLoadingMore = false
    /// 追加読み込みに失敗したカーソル。同じ値で繰り返し叩かないために持つ。
    @State private var failedCursor: String?

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            content
        }
        .navigationTitle(source.title(settings.language))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    reloadToken += 1
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(Theme.accent)
                }
            }
        }
        // reloadToken が変わるたびにループを再起動する。
        // 画面を離れるとキャンセルされ、戻ると自動で再開する。
        .task(id: reloadToken) {
            await runRefreshLoop()
        }
    }

    /// 取得 → 待機 → 取得 … を繰り返す。
    /// Task はビューが消えると自動でキャンセルされるため、Timer の後始末は不要。
    private func runRefreshLoop() async {
        while !Task.isCancelled {
            await load()

            let interval = settings.refreshInterval
            guard interval > 0 else { return }

            do {
                try await Task.sleep(for: .seconds(interval))
            } catch {
                return // キャンセル
            }
        }
    }

    private func load() async {
        // 追加読み込みと競合させない。
        // 追加読み込み中に取得を始めると、後から届いた先頭ページで
        // 読み込み済みの続きが消える。次回のタイマーで取り直せばよい。
        guard !isLoadingMore else { return }

        // 初回のみローディング表示。2回目以降は前の内容を出したまま更新する。
        switch state {
        case .loaded, .demo, .empty: break
        default: state = .loading
        }

        // 未認証 かつ フィードURL未設定 → 埋め込みサンプルを表示
        if !settings.isAuthenticated && settings.feedURL.isEmpty {
            state = .demo(loadDemo())
            return
        }

        do {
            let tweets: [Tweet]
            var cursor: String?

            if !settings.feedURL.isEmpty {
                tweets = try await fetchFromURL(settings.feedURL)
                cursor = nil   // 任意URLはページング非対応
            } else {
                let page = try await XClient().fetch(source: source, settings: settings)
                tweets = page.tweets
                cursor = page.nextCursor
            }

            // 取得中に画面を離れた場合は捨てる。
            // 追加読み込みの開始は先頭のガードで弾いているので、ここでは見ない。
            if Task.isCancelled { return }

            nextCursor = cursor
            failedCursor = nil   // 先頭を取り直したので、追加読み込みを再試行できる
            let limited = Array(tweets.prefix(settings.maxItems))
            state = limited.isEmpty ? .empty : .loaded(limited)

        } catch XClientError.notAuthenticated {
            guard !Task.isCancelled else { return }
            state = .demo(loadDemo())
        } catch {
            guard !Task.isCancelled else { return }
            // 前の内容が出ていれば、それを保ったままにする。
            // 何も出ていなければエラーを表示する。
            switch state {
            case .loaded, .demo: break
            default: state = .failed
            }
        }
    }

    /// 続きを読み込む。既存の内容に追記する。
    private func loadMore() async {
        // 任意URLのモードではページングできない
        guard settings.feedURL.isEmpty else { return }
        guard let cursor = nextCursor, !isLoadingMore else { return }
        guard case .loaded(let current) = state else { return }

        // 同じカーソルで続けて失敗したら、それ以上は試さない。
        if failedCursor == cursor { return }

        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            let page = try await XClient().fetch(source: source,
                                                 cursor: cursor,
                                                 settings: settings)

            // カーソルが進まない、または同じ値なら末尾に着いた
            guard let next = page.nextCursor, next != cursor else {
                nextCursor = nil
                return
            }
            nextCursor = next
            failedCursor = nil

            // 既存と重複するIDは除いて追記する。
            // 新しい項目が無くても、カーソルは進んでいるので読み込みは続ける。
            // 同一ページ内の重複も避けるため、追記分の中でも重複を除く。
            var seen = Set(current.map(\.id))
            var fresh: [Tweet] = []
            for t in page.tweets where !seen.contains(t.id) {
                seen.insert(t.id)
                fresh.append(t)
            }
            if !fresh.isEmpty {
                state = .loaded(current + fresh)
            }

        } catch {
            // 追加読み込みの失敗は画面全体を壊さない。
            // 同じカーソルで繰り返し叩かないよう記録しておく。
            // 定期更新で先頭を取り直すと failedCursor は消えるので、
            // その後にまた試せる。
            failedCursor = cursor
        }
    }

    /// Bundle の feeds.json からサンプルを読む（未認証時のフォールバック）
    private func loadDemo() -> [Tweet] {
        guard let url = Bundle.main.url(forResource: "feeds", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let table = try? JSONDecoder().decode([String: [Tweet]].self, from: data)
        else { return [] }

        // TimelineSource をサンプルのスレッドに対応させる
        let key: String
        switch source {
        case .following: key = "thread-1"
        case .forYou:    key = "thread-2"
        case .user:      key = "thread-3"
        }

        let tweets = table[key] ?? []
        return Array(tweets.prefix(settings.maxItems))
    }

    /// Settings で指定された任意の JSON URL から取得（file:// にも対応）
    private func fetchFromURL(_ urlString: String) async throws -> [Tweet] {
        guard let url = URL(string: urlString) else { throw XClientError.decoding }

        if url.isFileURL {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([Tweet].self, from: data)
        }

        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw XClientError.http(http.statusCode)
        }
        return try JSONDecoder().decode([Tweet].self, from: data)
    }

    @ViewBuilder
    private var content: some View {
        switch state {

        case .loading:
            ProgressView()
                .tint(Theme.accent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .empty:
            message(settings.t("まだXの投稿はありません", "No posts yet"))

        case .failed:
            message(settings.t("読み込めませんでした", "Could not load"))

        case .demo(let tweets):
            ScrollView {
                LazyVStack(spacing: Theme.cardSpacing) {
                    demoBanner
                    ForEach(tweets) { tweet in
                        TweetCard(tweet: tweet, language: settings.language)
                    }
                }
                .padding(.top, Theme.cardTop)
                .padding(.horizontal, Theme.cardSide)
                .padding(.bottom, Theme.cardBottom)
            }

        case .loaded(let tweets):
            ScrollView {
                LazyVStack(spacing: Theme.cardSpacing) {
                    ForEach(tweets) { tweet in
                        TweetCard(tweet: tweet, language: settings.language)
                    }

                    // 末尾に達したら続きを読む。
                    // id に nextCursor を渡しているので、カーソルが進むたびに再実行される。
                    if let cursor = nextCursor {
                        loadMoreTrigger(cursor: cursor)
                    }
                }
                .padding(.top, Theme.cardTop)
                .padding(.horizontal, Theme.cardSide)
                .padding(.bottom, Theme.cardBottom)
            }
        }
    }

    /// 一覧の末尾に置く読み込みトリガー。表示されたら続きを取りに行く。
    private func loadMoreTrigger(cursor: String) -> some View {
        HStack {
            Spacer()
            if isLoadingMore {
                ProgressView().tint(Theme.accent)
            } else {
                Color.clear.frame(height: 1)
            }
            Spacer()
        }
        .frame(height: 44)
        .task(id: cursor) {
            await loadMore()
        }
    }

    private var demoBanner: some View {
        NavigationLink {
            SettingsView()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.system(size: 13))
                Text(settings.t("サンプルデータを表示中 — 設定からログインしてください",
                                "Showing sample data — sign in from Settings"))
                    .font(.system(size: 12))
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.accent)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 15))
            .foregroundStyle(Theme.subtext)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// ============================================================
// MARK: - TweetCard
// ============================================================

struct TweetCard: View {
    let tweet: Tweet
    let language: AppLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // 上段: アイコン / ユーザー名 / 日付
            HStack(spacing: 8) {
                Image(systemName: "person.circle")
                    .font(.system(size: 25))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 25, height: 25)

                Text(tweet.userName)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text(Self.dateText(tweet.createdAt, language: language))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.subtext)
                    .lineLimit(1)
            }

            // 中段: 本文
            Text(tweet.text)
                .font(.system(size: 15))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)

            // メディア
            if !tweet.media.isEmpty {
                MediaGrid(media: tweet.media)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
            }

            // 引用ツイート
            if let quoted = tweet.quoted {
                QuotedCard(quoted: quoted)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
            }

            // 下段: エンゲージメント
            HStack(spacing: 24) {
                metric("heart", tweet.likes)
                metric("arrow.2.squarepath", tweet.reposts)
                metric("bubble.left", tweet.replies)
                Spacer()
            }
            .padding(.top, hasAttachment ? 0 : 12)
        }
        .padding(Theme.cardPadding)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var hasAttachment: Bool {
        !tweet.media.isEmpty || tweet.quoted != nil
    }

    private func metric(_ symbol: String, _ value: Int) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(Theme.subtext)
            Text(Self.compact(value))
                .font(.system(size: 13))
                .foregroundStyle(Theme.subtext)
        }
    }

    static func compact(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...:     return String(format: "%.1fK", Double(n) / 1_000)
        default:           return "\(n)"
        }
    }

    static func dateText(_ date: Date, language: AppLanguage) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: language == .ja ? "ja_JP" : "en_US")
        f.dateFormat = language == .ja ? "M月d日 HH:mm" : "MMM d, HH:mm"
        return f.string(from: date)
    }
}

// ============================================================
// MARK: - MediaGrid（画像・動画）
// ============================================================

struct MediaGrid: View {
    let media: [Media]

    private var columns: [GridItem] {
        let n = media.count == 1 ? 1 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 4), count: n)
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(Array(media.prefix(4).enumerated()), id: \.offset) { _, item in
                MediaTile(media: item, isSingle: media.count == 1)
            }
        }
    }
}

struct MediaTile: View {
    let media: Media
    let isSingle: Bool

    @State private var playing = false

    var body: some View {
        ZStack {
            AsyncImage(url: URL(string: media.url)) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                case .failure:
                    Color(hex: 0x2A2A2A)
                default:
                    Color(hex: 0x2A2A2A)
                }
            }

            // 動画とGIFは再生ボタンを重ねる
            if media.isPlayable && !playing {
                Button {
                    playing = true
                } label: {
                    ZStack {
                        Color.black.opacity(0.35)
                        Image(systemName: media.kind == .animatedGif
                              ? "circle.dashed" : "play.circle.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(.white)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(media.kind == .animatedGif ? "GIFを再生" : "動画を再生")
            }

            // 再生中は動画に差し替える。タップで停止してサムネイルに戻る。
            if playing, let videoUrl = media.videoUrl, let url = URL(string: videoUrl) {
                InlineVideoPlayer(url: url, isLooping: media.kind == .animatedGif)
                Button {
                    playing = false
                } label: {
                    Color.clear
                }
                .buttonStyle(.plain)
                .accessibilityLabel("再生を停止")
            }
        }
        .frame(height: isSingle ? 220 : 140)
        .frame(maxWidth: .infinity)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// ============================================================
// MARK: - InlineVideoPlayer
// ============================================================

/// カード内で動画を再生する。AVPlayerViewController を使わず、
/// AVPlayerLayer を持つ UIView を SwiftUI に載せる。
struct InlineVideoPlayer: UIViewRepresentable {
    let url: URL
    let isLooping: Bool

    final class Coordinator {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PlayerView {
        let v = PlayerView()
        v.backgroundColor = .black
        v.load(url: url, looping: isLooping)
        return v
    }

    func updateUIView(_ uiView: PlayerView, context: Context) {}

    static func dismantleUIView(_ uiView: PlayerView, coordinator: Coordinator) {
        uiView.stop()
    }

    final class PlayerView: UIView {
        private var player: AVPlayer?
        private var looper: AVPlayerLooper?

        override static var layerClass: AnyClass { AVPlayerLayer.self }

        private var playerLayer: AVPlayerLayer {
            layer as! AVPlayerLayer
        }

        func load(url: URL, looping: Bool) {
            let item = AVPlayerItem(url: url)

            if looping {
                let q = AVQueuePlayer()
                looper = AVPlayerLooper(player: q, templateItem: item)
                player = q
            } else {
                let p = AVPlayer(playerItem: item)
                player = p
            }

            playerLayer.player = player
            playerLayer.videoGravity = .resizeAspect
            player?.play()
        }

        func stop() {
            player?.pause()
            player = nil
            looper = nil
        }
    }
}

// ============================================================
// MARK: - QuotedCard（引用ツイート）
// ============================================================

struct QuotedCard: View {
    let quoted: QuotedTweet

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "person.circle")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.subtext)

                Text(quoted.userName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)

                if !quoted.screenName.isEmpty {
                    Text("@\(quoted.screenName)")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.subtext)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }

            Text(quoted.text)
                .font(.system(size: 13))
                .foregroundStyle(Theme.text.opacity(0.9))
                .lineLimit(6)
                .fixedSize(horizontal: false, vertical: true)

            if let urlString = quoted.imageUrl, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color(hex: 0x2A2A2A)
                    }
                }
                .frame(height: 140)
                .frame(maxWidth: .infinity)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Theme.separator, lineWidth: 1)
        )
    }
}

// ============================================================
// MARK: - 3. SettingsView
// ============================================================

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    @State private var syncing = false
    @State private var syncMessage: String?

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            Form {
                authSection
                queryIdSection
                displaySection
                sourceSection
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
        }
        .navigationTitle(settings.t("設定", "Settings"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }

    // MARK: 認証

    private var authSection: some View {
        Section {
            SecureField("auth_token", text: $settings.authToken)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            SecureField("ct0", text: $settings.ct0)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            TextField("Bearer", text: $settings.bearerToken)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 12, design: .monospaced))

            HStack {
                Text(settings.t("状態", "Status"))
                Spacer()
                Text(settings.isAuthenticated
                     ? settings.t("設定済み", "Configured")
                     : settings.t("未設定", "Not set"))
                    .foregroundStyle(settings.isAuthenticated ? Theme.accent : Theme.subtext)
            }
        } header: {
            Text(settings.t("認証（ブラウザのCookie）", "Auth (browser cookies)"))
        } footer: {
            Text(settings.t(
                "PCのブラウザで x.com にログインし、DevTools の Application タブにある "
                + "Cookies から auth_token と ct0 をコピーして貼り付けてください。",
                "Log in to x.com on a desktop browser, then copy auth_token and ct0 "
                + "from Cookies under the Application tab in DevTools."
            ))
            .font(.system(size: 12))
        }
    }

    // MARK: queryId

    private var queryIdSection: some View {
        Section {
            TextField("HomeTimeline", text: $settings.homeQueryId)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 12, design: .monospaced))

            TextField("HomeLatestTimeline", text: $settings.homeLatestQueryId)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 12, design: .monospaced))

            TextField("UserTweets", text: $settings.userTweetsQueryId)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 12, design: .monospaced))

            Button {
                Task { await sync() }
            } label: {
                HStack(spacing: 8) {
                    if syncing {
                        ProgressView().tint(Theme.accent)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    Text(settings.t("queryIdを同期", "Sync queryIds"))
                }
                .foregroundStyle(Theme.accent)
            }
            .disabled(syncing || !settings.isAuthenticated)

            if let msg = syncMessage {
                Text(msg)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.subtext)
            }
        } header: {
            Text("queryId")
        } footer: {
            Text(settings.t(
                "Xのデプロイで変わります。「同期」で x.com のJSバンドルから自動取得します。",
                "These change with X deploys. Tap Sync to fetch them from the x.com JS bundle."
            ))
            .font(.system(size: 12))
        }
    }

    private func sync() async {
        syncing = true
        syncMessage = nil
        defer { syncing = false }

        let found = (try? await XClient().syncQueryIds(settings: settings)) ?? [:]

        // 見つかった値を入れ、残りは既定値で埋める
        for key in QueryIdKey.allCases {
            if let value = found[key] {
                settings.setQueryId(value, for: key)
            } else if let fallback = XConstants.fallbackQueryIds[key.operationName] {
                settings.setQueryId(fallback, for: key)
            }
        }

        if found.isEmpty {
            syncMessage = settings.t(
                "取得できませんでした。既定値のままです",
                "Could not fetch. Using defaults."
            )
        } else {
            syncMessage = settings.t(
                "\(found.count)件を更新しました（残りは既定値）",
                "Updated \(found.count) (rest are defaults)"
            )
        }
    }

    // MARK: 表示

    private var displaySection: some View {
        Section {
            Stepper(value: $settings.refreshInterval, in: 30...600, step: 30) {
                HStack {
                    Text(settings.t("更新間隔", "Refresh interval"))
                    Spacer()
                    Text("\(Int(settings.refreshInterval))s")
                        .foregroundStyle(Theme.subtext)
                }
            }

            Stepper(value: $settings.maxItems, in: 1...100) {
                HStack {
                    Text(settings.t("最大表示件数", "Max items"))
                    Spacer()
                    Text("\(settings.maxItems)")
                        .foregroundStyle(Theme.subtext)
                }
            }

            Picker(settings.t("表示言語", "Language"), selection: $settings.language) {
                ForEach(AppLanguage.allCases) { lang in
                    Text(lang.label).tag(lang)
                }
            }
        } header: {
            Text(settings.t("表示", "Display"))
        }
    }

    // MARK: データソース

    private var sourceSection: some View {
        Section {
            TextField(settings.t("空ならX APIを使用", "Empty = use X API"),
                      text: $settings.feedURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .font(.system(size: 13))

            TextField(settings.t("ユーザーID（数字）", "User ID (numeric)"),
                      text: $settings.userID)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.numberPad)
        } header: {
            Text(settings.t("データソース", "Data source"))
        } footer: {
            Text(settings.t(
                "URLを入れると、X APIの代わりにそのURLからJSONを取得します（file:// も可）。",
                "If set, JSON is fetched from this URL instead of the X API (file:// works too)."
            ))
            .font(.system(size: 12))
        }
    }
}
