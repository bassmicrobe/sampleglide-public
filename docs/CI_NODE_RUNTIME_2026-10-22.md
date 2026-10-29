# CI の Node.js 内部ランタイム（2026-10-22）

GitHub Actions の checkout を v4（内部 Node.js 20）から公式 v7（内部 Node.js 24）へ更新しました。アプリ本体は Swift のままで、Node.js 26 をアプリ実行要件として追加していません。公式 action の提供する Node.js 24 を使用します。

GitHub hosted Ubuntu / macOS runner で既存の秘密情報検査と build / test を確認します。workflow の起動条件、権限、テスト内容、アプリ依存関係、署名・リリース・本番配備の扱いは変更しません。checkout v7 は runner 2.327.1 以上が必要で、self-hosted へ移す場合は事前確認してください。詳細は [公式 checkout リリース説明](https://github.com/actions/checkout/tree/v7) を参照してください。
