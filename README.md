# ぷりんCut

スマホで使える切り抜き動画編集アプリ。

- `www/index.html` … アプリ本体（ブラウザ版と同じ画面）
- `ios/` … iPhoneアプリ（Capacitor）。`ios/App/App/AppDelegate.swift` にiPhoneの機能（動画の読み込み・音声解析・文字起こし・カメラロール保存）
- `.github/workflows/ios.yml` … GitHub上のMacで自動ビルドし、Releases に `purincut.ipa` を置きます

## iPhoneに入れる
1. [Releases](../../releases/latest) から `purincut.ipa` をダウンロード
2. Windowsの Sideloadly で iPhone に入れる（無料のApple IDは7日ごとに入れ直し）
