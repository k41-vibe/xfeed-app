# xfeed-app

X（Twitter）のタイムラインを **WKWebView を使わずに** 表示する iOS アプリ。

通信はすべて `URLSession`、描画はすべて SwiftUI。WebKit を一切読み込まないため、
スクリーンタイムの「Web コンテンツ」制限の判定対象にならない。

- iOS 18.0 以上 / iPhone・iPad 両対応
- ダークテーマ固定
- 単一ファイル実装（`ContentView.swift` に Model・通信・全 View を集約）

---

## ファイル構成

```
xfeed-app/
├── Sources/xfeed-app/
│   ├── AppMain.swift          # @main
│   ├── ContentView.swift      # Model + XClient + 全 View
│   ├── Info.plist
│   └── Resources/
│       └── feeds.json         # 未認証時に表示するサンプル
├── project.yml                # XcodeGen 設定
└── README.md
```

---

## ビルド

### 1. XcodeGen で `.xcodeproj` を生成

```bash
brew install xcodegen
cd xfeed-app
xcodegen generate
```

### 2. Xcode で開いてビルド

```bash
open xfeed-app.xcodeproj
```

Signing & Capabilities で Team を設定し、実機に転送する。

### 3. LiveContainer 用の IPA を作る

```bash
xcodebuild -project xfeed-app.xcodeproj \
           -scheme xfeed-app \
           -configuration Release \
           -sdk iphoneos \
           -derivedDataPath build \
           CODE_SIGNING_ALLOWED=NO \
           build

# Payload を作って IPA に固める
mkdir -p Payload
cp -R build/Build/Products/Release-iphoneos/xfeed-app.app Payload/
zip -r xfeed-app.ipa Payload
```

できた `xfeed-app.ipa` を LiveContainer に読み込ませる。

> LiveContainer は署名なしで動かす前提のため `CODE_SIGNING_ALLOWED=NO` でビルドしている。
> 通常の実機転送をしたい場合は Team を設定して普通にビルドすること。

---

## 認証（ブラウザの Cookie を使う方式）

X はプログラムからのログインを意図的に妨害している（Arkose CAPTCHA、2FA、
JS が生成する `x-client-transaction-id` ヘッダー）。そのためアプリ内でログインを
完結させるのは現実的でない。

代わりに、ブラウザでログイン済みのセッション Cookie をコピーして使う。
これは X-CLI と同じ方式。

### 手順

1. PC のブラウザで https://x.com にログインする
2. DevTools を開く（F12）
3. `Application` タブの `Cookies` を開き、`https://x.com` を選ぶ
4. 次の 2 つの値をコピーする
   - `auth_token`
   - `ct0`
5. アプリの設定画面の「認証」に貼り付ける

以降、アプリは `Cookie: auth_token=...; ct0=...` を付けて `URLSession` で
X の GraphQL API を直接叩く。X 側から見れば正規のログイン済みセッションなので、
通常のタイムラインが返る。

> Cookie はパスワードと同等の権限を持つ。他人と共有しないこと。
> 失効したらブラウザで再ログインしてコピーし直す。

---

## X API の仕様（2026-09 時点の調査結果）

### リクエストは POST

X の内部 GraphQL は `https://x.com/i/api/graphql/{queryId}/{OperationName}` に対して
POST を要求する。GET は 404 を返す。

2026-08 に SearchTimeline と Followers が GET を廃止した。UserTweets はまだ GET を
受け付けるが、HomeTimeline は以前から POST のみ。この実装は全エンドポイントを
POST に統一している（POST はすべてのエンドポイントで通る）。

ボディは次の形。`queryId` は URL とボディの両方に入れる。

```json
{
  "variables": { "count": 20, "includePromotedContent": false, "...": "..." },
  "features":  { "longform_notetweets_consumption_enabled": true, "...": "..." },
  "queryId":   "c-CzHF1LboFilMpsx4ZCrQ"
}
```

ヘッダーには `Content-Type: application/json` が要る。

### features は false を送らない

X は未指定の feature を false として扱う。false を明示するとボディが長くなるだけで
利点がない。この実装は true のものだけを送る。

### queryId は 2〜4 週ごとに回転する

`queryId` は X のデプロイごとに変わる。目安として 2〜4 週間で無効になる。
無効な `queryId` で叩くと 404 が返る。

そのため、この実装は 404 を受けると自動で queryId を同期し直して1度だけ再試行する。

---

## queryId の同期

設定画面の「queryIdを同期」は次の順に解決する。

| 順 | 取得元 | 内容 |
|---|---|---|
| 1 | x.com の JS バンドル | HTML から `client-web/*.js` を全部拾い、`queryId:"..."` と `operationName:"..."` の組を正規表現で抽出 |
| 2 | コミュニティ一覧 | `fa0311/twitter-openapi` の `placeholder.json` |
| 3 | コード内の既定値 | `XConstants.fallbackQueryIds` |

1 が成功すれば最新の値が入る。2 と 3 は保険。

手動で入れたい場合は、ブラウザの DevTools の Network タブで `graphql` を含む
リクエストを見れば URL から読み取れる。

---

## 画面

| 画面 | 内容 |
|---|---|
| トップ | タイムライン種別の一覧（フォロー中 / おすすめ / ユーザー） |
| フィード | ツイートカードの一覧。更新間隔ごとに自動更新。末尾で続きを自動読み込み |
| 設定 | 認証・queryId・表示設定・データソース |

### 表示できるもの

| 種類 | 対応 |
|---|---|
| 本文 | 対応。URLはプレーンテキストのまま |
| 画像 | 1枚は大きく、2〜4枚は格子で表示 |
| 動画 | サムネイルに再生ボタン。タップでカード内再生、もう一度タップで停止 |
| GIF | 同上。ループ再生 |
| 引用ツイート | 枠付きで本文と画像を表示 |

### 無限スクロール

一覧の末尾に達すると、`cursor` を使って続きを自動で読み込みます。
取得済みのIDと重複する項目は除外します。新しい項目が1件も無ければ、
そこで読み込みを止めます（同じカーソルを回り続けるのを防ぐため）。

「設定 → データソース → フィードURL」で任意のURLを指定している場合は、
ページングに対応しないため、末尾まで行っても追加読み込みはしません。

### フィードの状態表示

| 状態 | 表示 |
|---|---|
| 読み込み中 | `ProgressView` |
| 取得成功・0件 | 「まだXの投稿はありません」 |
| エラー | 「読み込めませんでした」 |
| 未認証 | 埋め込みサンプル + 案内バナー |

---

## 設定項目（UserDefaults に保存）

| 項目 | 既定値 | 範囲 |
|---|---|---|
| 更新間隔 | 30 秒 | 30〜600 秒 |
| 最大表示件数 | 20 | 1〜100 |
| 表示言語 | 日本語 | 日本語 / English |
| フィードURL | 空 | 空なら X API を使用。`file://` も可 |
| ユーザーID | 空 | 「ユーザー」タブで使う数値 ID |

---

## データソースの切り替え

設定画面の「データソース」にある「フィードURL」に URL を入れると、X API の代わりに
その URL から JSON を取得する。配列形式の JSON を返せばよい。

```json
[
  {
    "id": "1001",
    "userName": "テック速報",
    "screenName": "techflash",
    "text": "本文",
    "imageUrl": null,
    "likes": 1240,
    "reposts": 382,
    "replies": 94,
    "createdAt": "2026-09-20T09:12:00Z"
  }
]
```

`file://` スキームにも対応しているので、`Resources/feeds.json` を直接指すこともできる。

---

## スクリーンタイムについて

このアプリは `WebKit` / `WKWebView` / `SafariServices` を **import していない**。
通信は `URLSession` のみ。

iOS のスクリーンタイムにおける Web コンテンツ制限は、WebKit の読み込み処理が
ページのホストを見て判定する。`URLSession` はその経路を通らないため、
アプリの通信はカウントされない。

確認するには、スクリーンタイムで「Web コンテンツ」の使用時間が
このアプリの使用中に増えないことを見ればよい。

---

## うまくいかないとき

| 症状 | 原因と対処 |
|---|---|
| 「読み込めませんでした」が出る | 設定の「状態」が未設定なら Cookie を入れる。設定済みなら Cookie が失効している。ブラウザで再ログインしてコピーし直す |
| HTTP 404 が続く | `queryId` が回転した。設定の「queryIdを同期」を押す。自動再試行でも直らない場合は手動で入れる |
| HTTP 403 が返る | `x-client-transaction-id` ヘッダーを要求されている可能性がある。下の「制限事項」を参照 |
| 0件のまま | 「ユーザー」タブは設定に数値のユーザーIDが必要。プロフィールURLの `/x.com/名前` ではなく、数値のIDを入れる |
| サンプルのまま変わらない | Cookie が未入力。設定の「状態」が「設定済み」になっているか確認する |

---

## レスポンスの解析

X のレスポンスは入れ子が深く、パス構造も頻繁に変わります。そのためパスを決め打ちせず、
JSON ツリーを走査して「`legacy` を持ち `full_text` がある」辞書をツイートとして拾います。

走査時に2つ除外します。

| 除外するもの | 理由 |
|---|---|
| `retweeted_status_result` と `quoted_status_result` の中身 | 辿ると別IDのツイートとして二重に並ぶ |
| `card.name` が `promo` で始まるもの | プロモーション（広告） |

---

## 制限事項

- X の非公開 API を使っている。X の利用規約に触れる可能性がある。自己責任で、個人利用の範囲で使うこと
- `queryId` は 2〜4 週ごとに回転する。404 が出たら「同期」を押す
- `x-client-transaction-id` は実装済みだが未検証。403 が返ったときに自動で付けて再試行する。ただし animation_key の計算は SVG の補間を省略した簡易版なので、X 側の検証を通るかは確認できていない
- Cookie が失効したら設定から入れ直す
- 返信、いいね、投稿などの書き込み操作には対応していない。読み取り専用

---

## 出典

X API の仕様は次を参照した（2026-09-20 時点）。

| 内容 | 出典 |
|---|---|
| HomeTimeline が POST であること、ボディの形 | trekhleb, "API Design of X (Twitter) Home Timeline" (2024-12) https://trekhleb.dev/blog/2024/api-design-x-home-timeline/ |
| GET 廃止の進行と queryId の有効性 | nirholas/XActions issue #42 (2026-08-20) https://github.com/nirholas/XActions/issues/42 |
| queryId の 3段階解決、features の圧縮 | jackwener/twitter-cli https://github.com/jackwener/twitter-cli |
| queryId の回転周期（2〜4週） | ScrapFly, "How to Scrape Twitter (X.com) Data in 2026" (2026-08-27) https://scrapfly.io/blog/posts/how-to-scrape-twitter |
| 既定の queryId 値 | jackwener/twitter-cli の FALLBACK_QUERY_IDS |
