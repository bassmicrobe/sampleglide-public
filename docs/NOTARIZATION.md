# Developer ID署名・Apple公証

SampleGlideをMac App Store以外で配布するための手順です。通常の `build-app.sh` は開発用のアドホック署名を行い、`notarize-app.sh` は独立したreleaseアプリを作り、Developer ID署名、Apple公証、チケット添付、配布ZIPの検証を行います。認証情報や署名鍵はリポジトリへ保存しません。

## 必要な設定

- macOS、Xcode、Apple Developer Programの対象チーム。
- 対象チームの有効な **Developer ID Application** 証明書と対応する秘密鍵。`Apple Development`、`Developer ID Installer` は使用しません。
- 同じチームの公証用キーチェーンプロファイル。既存設定を再利用する場合も、チームと有効性を確認します。

有効な署名identityを確認します。専用キーチェーンを使う場合は、そのファイルも引数に指定してください。

```sh
security find-identity -v -p codesigning
```

証明書がなければ、Xcodeの **Settings > Apple Accounts > Manage Certificates** または[Apple Developerの証明書作成手順](https://developer.apple.com/help/account/certificates/create-developer-id-certificates)に従って取得します。別のMacの証明書を移す場合は秘密鍵も必要で、`.cer` だけでは署名できません。

Apple Account方式で公証する場合は、[Apple Account](https://account.apple.com/)でアプリ用パスワードを作成し、Terminalから次を実行します。

```sh
apps/macos/scripts/setup-notarization.command
```

Apple Account、Team ID、アプリ用パスワードを `notarytool` の対話プロンプトへ入力します。既定の保存先プロファイル名は `sampleglide-notary` です。パスワードをコマンド引数、チャット、ソース、`.env` に記載しないでください。App Store Connect APIキー方式を使う場合は、Appleの手順に従って同じくキーチェーンプロファイルへ登録します。

## 設定確認と実行

リポジトリのルートで実行します。`--check` は署名identityとApple側の認証を確認するだけで、ビルドやアプリの送信は行いません。

```sh
apps/macos/scripts/notarize-app.sh --check
apps/macos/scripts/notarize-app.sh
```

有効なDeveloper ID Application identityが複数ある場合は、対象を明示します。専用キーチェーンを使う場合は、検索と署名の両方に同じファイルが使用されます。

```sh
CODE_SIGN_IDENTITY='YOUR_CERTIFICATE_SHA1_FINGERPRINT' \
CODE_SIGN_KEYCHAIN='/absolute/path/to/signing.keychain-db' \
NOTARY_KEYCHAIN_PROFILE='your-team-notary-profile' \
apps/macos/scripts/notarize-app.sh
```

`CODE_SIGN_IDENTITY` は証明書の完全な名前でも指定できます。`CODE_SIGN_KEYCHAIN` を省略すると通常のキーチェーン検索を使います。署名鍵の使用許可を求められた場合は、画面に表示されたキーチェーンのパスワードを入力します。Apple Accountのパスワードや公証用アプリ用パスワードとは別のものです。

`/Applications/Xcode.app` が存在すればスクリプト内で優先し、システム全体の `xcode-select` は変更しません。別のツールチェーンには `DEVELOPER_DIR` を指定してください。

## 出力と検証範囲

出力先は `apps/macos/dist/notarization/run-日時.ランダム文字列/` です。開発用の `dist/SampleGlide.app` やインストール済みアプリは上書きしません。アプリはビルドしたMacの既定アーキテクチャで作成し、配布ZIPの名前は実際の実行ファイルを `lipo -archs` で調べて決定します。

1. 独立したreleaseアプリをDeveloper ID、Hardened Runtime、セキュアタイムスタンプで署名します。
2. 申請ZIPをAppleへ送信し、`submission.json` と `submission-id.txt` に申請IDを保存してから、最大30分待機します。
3. `status.json` の `Accepted` を確認し、公証ログを保存して同じアプリにチケットを添付します。
4. チケット、厳密な署名、Gatekeeper判定を検証します。
5. チケット添付後のアプリから配布ZIPとSHA-256ファイルを作成します。
6. SHA-256を照合し、配布ZIPを `verification/` へ展開して、チケット・署名・Gatekeeperとアーキテクチャを再検証します。

配布対象は **`SampleGlide-macOS-arm64.zip`** とその `.sha256` ファイルです。実際にx86_64の実行ファイルをビルドした場合は `x86_64`、両方を含む場合は `universal` となります。通常のビルドスクリプトはUniversal Binaryを作成しません。`submission.zip` はチケット添付前の申請用で、配布用ではありません。

最終行に `Verified notarized distribution archive:` と表示されたZIPを使用します。この処理はローカルでの配布物作成までを行います。公証はアプリの機能試験、Intel実機試験、DAW互換性試験を代替しません。

現在のアプリは単一実行ファイルとリソース専用Bundleのみで、公証のための追加entitlementsは使用しません。将来helper、framework、プラグインなどの実行コードを同梱する場合は、内側から署名する処理を追加してください。

## タイムアウト・失敗時

作業ディレクトリは保持されます。申請IDが得られている場合は、同じアプリを再送する前にそのIDで確認・待機します。タイムアウトしてもApple側の処理は続く場合があります。

```sh
xcrun notarytool info SUBMISSION_ID --keychain-profile your-team-notary-profile
xcrun notarytool wait SUBMISSION_ID --keychain-profile your-team-notary-profile --timeout 30m
xcrun notarytool log SUBMISSION_ID --keychain-profile your-team-notary-profile notary-log.json
```

後から `Accepted` になった場合は、同じ申請ディレクトリのアプリに対してチケットを添付し、検証してから配布ZIPを作成します。署名後のアプリ内容を変更した場合は再署名・再公証が必要です。

```sh
APP='/absolute/path/to/run-directory/SampleGlide.app'
RUN_DIR='/absolute/path/to/run-directory'
ARCHIVE="$RUN_DIR/SampleGlide-macOS-arm64.zip"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
spctl --assess --type execute --verbose=2 "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
(cd "$RUN_DIR" && shasum -a 256 "$(basename "$ARCHIVE")" > "$(basename "$ARCHIVE").sha256")
(cd "$RUN_DIR" && shasum -a 256 --check "$(basename "$ARCHIVE").sha256")
VERIFICATION_DIR="$(mktemp -d "$RUN_DIR/verification-resume.XXXXXX")"
ditto -x -k "$ARCHIVE" "$VERIFICATION_DIR"
xcrun stapler validate "$VERIFICATION_DIR/SampleGlide.app"
codesign --verify --deep --strict --verbose=2 "$VERIFICATION_DIR/SampleGlide.app"
spctl --assess --type execute --verbose=2 "$VERIFICATION_DIR/SampleGlide.app"
xcrun lipo -archs "$VERIFICATION_DIR/SampleGlide.app/Contents/MacOS/SampleGlide"
```

ZIP名のアーキテクチャは実際のバイナリに合わせてください。Appleの公証ログにあるSHA-256は申請用ZIPの値で、チケット添付後の配布ZIPとは異なり得ます。

## Apple公式資料

- [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
