# SampleGlide

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="apps/macos/Assets/Brand/sampleglide-lockup-dark.svg">
  <source media="(prefers-color-scheme: light)" srcset="apps/macos/Assets/Brand/sampleglide-lockup-light.svg">
  <img src="apps/macos/Assets/Brand/sampleglide-lockup-light.svg" width="456" height="120" alt="SampleGlide">
</picture>

**欲しい音を、すぐ制作へ。**

## 概要

SampleGlideは、Mac内やNAS上のサウンドサンプルを探し、試聴・整理してDAWへ渡すネイティブmacOSアプリです。Finder風のカラム表示で階層をたどるほか、登録した素材フォルダ全体を名前・メモ・タグで検索できます。

Finderに接続済みのNASは、素材フォルダを追加するだけで使えます。この公開リポジトリにはmacOSアプリのソースを収録しています。Rust製NASサーバー、DBマイグレーション、外部設計資料、API仕様は含めていません。画面に残る任意の「共有索引」は互換APIを別途用意した場合のクライアント機能であり、この公開リポジトリだけでは利用できません。

**開発版：2026年10月15日時点のソースを公開しています。** すべての機能・動作環境を検証済みという意味ではありません。

主な未対応・未検証:

- BPM／キーの自動解析、DAWとの自動テンポ同期、出力機器の選択
- 波形ズーム、加工音声のリアルタイム処理、ギャップレスループ、加工キャッシュの容量制限
- 加工はモノラル／ステレオが対象。加工WAVは原音のサンプルレート・Float32形式で出力し、標準WAVの4 GBを超える出力は拒否
- Intel／macOS 14の実機試験、6 TB全量の性能試験、実素材の聴感品質、外部DAWへの実ドロップは未検証
- ソースからのビルドに対応。配布用の署名・公証済みアプリは未提供

このリポジトリは匿名化済みの現行ファイルから初期コミットした独立リポジトリです。旧リポジトリのGit履歴・実行ログ・ローカル設定は引き継いでいません。

## 技術スタック

| 項目 | 内容 |
|---|---|
| 言語 | Swift 5.10以降（検証環境は Swift 6.3.3） |
| UI | SwiftUI / AppKit |
| 音声 | AVFoundation / Core Audio（WAV／AIFF／FLAC。実際に再生できる符号化方式はCore Audioに依存） |
| 索引 | このMacのSQLite。SwiftPMの外部パッケージ依存なし |
| 対象OS | macOS 14以降 |
| CI | GitHub Actions（macOSビルド・テスト、Gitleaksによる全コミットの秘密情報検査） |

Apple Silicon / macOS 26 / Swift 6.3.3で検証しています。IntelとmacOS 14での実機試験は未実施です。

## セットアップ

| 必要環境 | 条件 |
|---|---|
| macOS | 14以降 |
| ビルドツール | Swift 5.10以降を含むXcode／Command Line Tools |
| ソース取得 | Git |

```sh
git clone https://github.com/bassmicrobe/sampleglide-public.git
cd sampleglide-public
bash apps/macos/scripts/build-app.sh
open 'apps/macos/dist/SampleGlide.app'
```

生成先は `apps/macos/dist/SampleGlide.app` です。`/Applications` への自動インストールは行いません。現時点ではアドホック署名で、配布用の署名・公証は未対応です。`build-app.sh debug` は開発用の高速ビルドです。

開発中はSwiftPMからも起動できます。

```sh
swift run --package-path apps/macos SampleGlide
```

検証:

```sh
swift build --package-path apps/macos
swift test --package-path apps/macos -Xswiftc -strict-concurrency=complete
```

## 使い方

フォルダ表示・全体検索・試聴は、アプリ単体で利用できます。API URL・ライブラリID・APIトークンの設定は不要です。SMBの認証はmacOSが管理します。

1. NASを使う場合は、Finderで共有フォルダへ接続します。
2. **「フォルダを追加」** で、Mac内またはNASの素材フォルダを選びます。
3. 左側の「場所」から階層をたどるか、検索欄・「全体検索」から登録したすべての場所を検索します。起動時にバックグラウンドで索引を作成し、名前・パス・メモ・タグを部分一致で探せます。索引は音声をコピーせず、BPM・キー解析も行いません。
4. 音声を選んで試聴し、右クリックからお気に入り・メモ・タグを追加します。
5. 下部の **「DAW へドラッグ」** から素材を渡します。未加工・全範囲は原音を直接ドラッグします。切り出し・テンポ・移調を変えた場合は加工WAVを自動準備します。原音は上書きしません。

NASのマウント先は環境や再接続によって変わる場合があります。接続・再接続は [NAS接続ガイド](docs/NAS_CONNECTION.md) を参照してください。操作の詳細は [macOS技術資料](apps/macos/README.md) にあります。

| 操作 | 動作 |
|---|---|
| ↑ / ↓ | カラム／全体検索で項目を選択。音声は自動試聴ONなら再生 |
| → | カラムでは選択したフォルダへ入る。全体検索では選択フォルダを開く |
| ← | カラムで親フォルダへ戻って試聴を停止 |
| Return / ダブルクリック | 全体検索で選択したフォルダを開く |
| Space | 試聴の再生・停止 |
| ⌘O | ローカル音声ファイルを開く |
| ⌘F | 検索欄へフォーカス |
| ⌘, | 試聴設定を開く |
| ⌘S | メモ・タグ編集画面で保存 |

| データ | 保存先 |
|---|---|
| 登録した場所、お気に入り、表示名、お気に入りフォルダ | `~/Library/Application Support/jp.samplebrowser/folders.json` |
| ファイル／ディレクトリのメモ・タグ | `~/Library/Application Support/jp.samplebrowser/annotations.json` |
| 全体検索の索引・読み込み再開情報 | `~/Library/Application Support/jp.samplebrowser/library-index.sqlite3` |
| 自動試聴のON／OFF | このMacのアプリ設定（UserDefaults） |
| 加工WAV | `~/Music/Sample Browser Exports/` |
| 共有APIの端末資格情報 | macOSのKeychain |

お気に入り・メモ・タグ・索引はMac内に保存し、原音へ書き込みません。Mac間の自動同期はありません。旧名Sample Browserからのデータ互換のため、`jp.samplebrowser` 系の識別子と `~/Music/Sample Browser Exports/` は維持しています。

## 構成

```text
.
├── apps/macos/          SwiftUI / AppKitアプリ、アイコン、テスト、ビルドスクリプト
│   ├── Sources/         アプリ本体
│   ├── Tests/           XCTest
│   ├── Assets/          アイコン・ロゴ
│   └── scripts/         アプリ／アイコンのビルド
├── docs/                NAS接続ガイド、監査・公開準備の記録
├── .github/workflows/   ビルド・テスト・秘密情報検査
├── LICENSE              MIT License
└── THIRD_PARTY_NOTICES.md
```

## ドキュメント

- [NAS接続ガイド](docs/NAS_CONNECTION.md)
- [性能・UI/UX監査（2026-10-04）](docs/PERFORMANCE_UIUX_AUDIT_2026-10-04.md)
- [公開準備の確認記録（2026-10-15）](docs/PUBLIC_RELEASE_REVIEW_2026-10-15.md)
- [CI の Node.js 内部ランタイム（2026-10-22）](docs/CI_NODE_RUNTIME_2026-10-22.md)
- [macOS技術資料](apps/macos/README.md)
- [ブランドアセット](apps/macos/Assets/README.md)
- [第三者ライセンス](THIRD_PARTY_NOTICES.md)

## ライセンス

独自コード、同梱ドキュメント、提供されたアプリアイコン・ロゴ、自作の合成テスト信号は、[MIT License](LICENSE)で提供します。著作権表示には公開アカウント名 `bassmicrobe` を使用しています。第三者のSDKや利用者が追加するサンプル音源には、それぞれの権利者の条件が適用されます。[第三者ライセンスについて](THIRD_PARTY_NOTICES.md)を参照してください。
