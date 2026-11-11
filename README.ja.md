# Classic Companion

[English](README.md) · [日本語](README.ja.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md)

<img src="assets/icon/AppIcon-1024.png" alt="Classic Companion アプリアイコン" width="80">

**ショートカットひとつで、ChatGPT を macOS のネイティブウインドウに。**

SwiftUI、AppKit、WKWebView で ChatGPT の公式サイトを表示するアプリです。`⌥ Space` で小さなウインドウを呼び出し、`⌃⌘F` で大きなウインドウに切り替えます。ショートカット設定、ログイン状態の保持、ページズーム、日本語・英語・簡体字中国語・繁体字中国語に対応しています。会話と読み上げは公式サイトの機能を使用します。OpenAI とは関係のない独立したアプリです。

これは [Apache-2.0](LICENSE) で公開する**ソースリポジトリ**です。配布と利用者向けフィードバックは [ClassicCompanion](https://github.com/mactokyo/ClassicCompanion) で扱います。

## レビューと検証

検証結果と未検証項目は[レビューガイド](docs/review.md)を参照してください。初回オフラインからの復旧修正を含みますが、公開済みベータ v0.1.0-beta.1（20261110.0137）には含まれません。

## ビルドとテスト

Apple silicon Mac、macOS 15 以降、Swift 6 対応のフル Xcode が必要です。今回の検証環境は Xcode 27.2 / Swift 6.4.2 / macOS 27.2 です。他のツールチェーンと最低 OS バージョンは未検証です。

```sh
git clone https://github.com/mactokyo/ClassicCompanion-App.git
cd ClassicCompanion-App
xcodebuild -version
swift --version
swift test
CC_SIGNING_MODE=adhoc scripts/build-app.sh debug
open "build/$(cat build/LATEST)/Classic Companion.app"
```

`swift test` はログイン済みの macOS デスクトップセッションで実行します。一部のテストは AppKit ウインドウと、合成ページを読み込む実際の WKWebView を使用し、ウインドウのテストでは一時的にウインドウが表示されるため、実行中は入力しないでください。自動テストに ChatGPT ログインは不要です。公式サイトの手動確認にはネット接続と ChatGPT アカウントが必要です。

debug は ad-hoc 署名を使うため、開発者の配布用証明書や公証の認証情報は不要です。ローカルレビュー用で、配布用ではありません。起動前にインストール済みのアプリを終了してください。同じ Bundle ID のため、設定と WebKit のログインデータを共有します。データを分離したい場合は別の macOS ユーザーを使ってください。出力先は `build/<タイムスタンプ>/` で、同じ分に二度ビルドすると拒否されます。

## ソース構成

| パス | 内容 |
| --- | --- |
| `Sources/ClassicCompanion/` | 起動、ウインドウ、ショートカット、WKWebView、DOM 対応、言語、診断 |
| `Sources/CompanionCore/` | ナビゲーション方針、URL の匿名化、ズーム、読み込み復旧 |
| `Tests/` | ロジック、言語、ネイティブ UI、合成 Web ページのテスト |
| `scripts/` | ビルド、配布パッケージ、公証、検証 |
| `assets/` | アイコンとデザイン素材 |

## 既知の制限

公式サイトの DOM 変更で Web 拡張が動かなくなる可能性があります。初回オフライン時の復旧はソースで修正済みですが、公開ビルドには未反映です。システムのオフライン通知（実際に Wi-Fi を切った場合）とログイン時の実起動は未検証です。画像プレビュー、対話型コンポーネント、読み上げ中の遷移、長い会話のスクロール、一部のウインドウ・IME 動作は追加確認が必要です。macOS 15/26、新規ユーザー、単一画面のフルスクリーン環境は検証範囲外で、Intel は非対応です。詳細は[ベータ版の説明](docs/trial-notes.ja.md)とレビューガイドを参照してください。


## 貢献とライセンス

[貢献方法](CONTRIBUTING.md)、[ブランド](BRANDING.md)、[配布設定](docs/release-signing.md)をご覧ください。コードと同梱素材は Apache-2.0、商標権は付与しません。
