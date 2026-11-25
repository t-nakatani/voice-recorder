# voice-recorder（録音の転送アプリ）

iPhone のロック画面から録音を始め、録音を必ず iPhone に残しつつ、S3 互換ストレージ（主に Cloudflare R2）へ送るアプリ。

- `ios/` … iPhone アプリ（Swift / SwiftUI、iOS 18+）。CI の対象外（Mac と Xcode が要る）
- `ingest/` … 署名付きURLを発行し、他の宛先へ複製する Worker（`voice-recorder-ingest`）

UI は仮のもの（`ios/App/DebugViews.swift`）。デザインは後で作り直す前提で、部品は UI から切り離している。

## 部品（プリミティブ）

`ios/RecorderKit` は Swift Package。部品ごとにモジュールを分け、**依存は「各部品 → RecorderCore」だけ**。組み立ては `RecorderRuntime` だけが行う。

| モジュール | 役割 | 主な型 |
|---|---|---|
| RecorderCore | 型と契約（protocol）。他に依存しない | `Recording` `Segment` `UploadJob` `ObjectKeys` `RecordingManifest` と `RecordingStore` `Destination` `UploadTransport` `AudioCapturing` |
| SegmentStore | 区切りファイルと録音台帳をローカルに保存。落ちた録音の復旧、削除してよいかの判断 | `FileRecordingStore` `RetentionPolicy` |
| UploadQueue | 宛先ごとの配送台帳と、送信・再送のスケジューラ | `UploadScheduler` `FileDeliveryLedger` `RetryPolicy` `DeliverySummary` |
| Destinations | 宛先の実装（Worker 発行の署名付きURL）、端末トークンの Keychain 保管、宛先設定 | `WorkerPresignDestination` `KeychainTokenStore` `DestinationConfig` |
| BackgroundTransport | バックグラウンド URLSession での送信 | `BackgroundURLSessionTransport` `InMemoryTransport` |
| AudioCapture | AVAudioEngine で録音し一定秒数ごとに独立した m4a に区切る。割り込み・経路変更からの再開 | `SegmentedAudioRecorder` `SegmentPlanner` `AudioFileProbe` |
| RecordingControl | Live Activity とロック画面 intent からアプリ本体を呼ぶ窓口 | `RecordingActivityAttributes` `LiveActivityController` `RecordingCommandCenter` `PendingStartFlag` |
| RecorderRuntime | 上をつなぐ。UI と intent はここだけを見る | `RecordingService` `AppEnvironment` `NetworkMonitor` |

アプリ側:

- `ios/Shared/RecordingIntents.swift` … App Intents（アプリとウィジェット拡張の両方にコンパイル）
  - `StartRecordingIntent`（方式A: AudioRecordingIntent、ロック解除なし）
  - `OpenAndRecordIntent`（方式B: アプリを開いて自動で録音）
  - `StopRecordingIntent`（Live Activity の停止ボタン）
- `ios/Widget/` … コントロール（ロック画面・コントロールセンター・アクションボタン）と Live Activity
- `ios/App/` … アプリ本体と仮 UI、ショートカット

## 録音を失わないための決まり

1. 録音は 30 秒ごとに独立した m4a に区切る。落ちても失うのは書きかけの1区切りだけ
2. ファイルを書き終えて名前を確定してから台帳に載せる。台帳にあるものは必ず実ファイルがある
3. ファイル保護は「初回ロック解除後」（ロック中でも書ける・送れる）
4. 起動時に、録音中のまま残った録音を閉じる。読める書きかけは区切りとして採用し、読めないものは `damaged/` に移して残す
5. 自動で消すのは「閉じた録音」で「全宛先に manifest まで届いた」かつ「保持期間を過ぎた」ものだけ。既定は消さない

## 送信の流れ

```
区切りを閉じる → UploadScheduler.pump
  → Destination.prepareUpload（Worker の /v1/presign で署名付き PUT URL をもらう）
  → BackgroundURLSessionTransport（ファイルから PUT。アプリが閉じていても OS が送る）
  → 結果で配送台帳を更新。失敗は 5 秒から 30 分まで間隔を伸ばして送り直す（諦めない）
録音を閉じる → manifest.json を作る → 全区切りが届いた宛先から manifest を送る
```

- キーは `recordings/<録音ID>/segments/000000.m4a` と `recordings/<録音ID>/manifest.json`。同じものを送り直しても上書きになるだけ
- 複数宛先は2通り。(1) アプリに宛先を複数登録する（それぞれへ iPhone から直接送る）、(2) Worker が R2 のイベント通知を受けて他の宛先へ複製する（`REPLICA_TARGETS`）

## Mac でのビルド

```sh
brew install xcodegen
cd ios
# Team ID は git に書かず、環境変数で渡す（自分の Apple Developer のチーム。値は Xcode の Settings > Accounts で見られる）
DEVELOPMENT_TEAM=<Team ID> xcodegen generate
open VoiceRecorder.xcodeproj
# 部品のテスト（Xcode なしでも可）
cd RecorderKit && swift test
```

## 最初の実機スパイクで確かめること

1. コントロールセンターに「録音」コントロールを置き、ロック中に押して録音が始まるか（方式A）
   - 失敗例として報告されているもの: `AVAudioSession.setActive` が 561015905 で失敗する、Live Activity が「Target is not foreground」で始まらない
2. 1 がだめなら「開いて録音」（方式B）で、Face ID 後に自動で録音が始まるか
3. アクションボタンに割り当てて同じことができるか
4. 録音中にロックしたまま 10 分置いて、区切りが送られ続けるか
5. 機内モードで録音 → 解除後に送られるか。録音中にアプリを強制終了 → 再起動で復旧されるか

## ingest（Worker）

```sh
cd ingest
pnpm install --frozen-lockfile
pnpm test
pnpm typecheck
```

API: `POST /v1/presign`（`Authorization: Bearer <端末トークン>`、本文 `{key, contentType, contentLength, sha256}`）→ `{url, method, headers, expiresAt}`。`GET /v1/health` は生存確認。

### 配置

1. R2 のバケットを作る（例: `wrangler r2 bucket create <バケット名>`）
2. `ingest/wrangler.toml.example` を `ingest/wrangler.toml` にコピーし、アカウントIDとバケット名を入れる（`wrangler.toml` はコミットしない）
3. R2 の API トークンを、そのバケットだけに Object Read & Write で作り、S3 用の鍵を secret に入れる。
   S3 用の秘密鍵はトークンを作った直後にしか読めない。定期的に入れ替える
   ```sh
   wrangler secret put R2_ACCESS_KEY_ID
   wrangler secret put R2_SECRET_ACCESS_KEY
   ```
4. 端末トークンを作り（`openssl rand -hex 32`）、iPhone の宛先設定に入れる。その SHA-256（`printf %s "$TOKEN" | shasum -a 256`）を secret に入れる（端末が複数ならカンマ区切り）
   ```sh
   wrangler secret put DEVICE_TOKEN_SHA256
   ```
5. `pnpm run deploy`（テストのあと `wrangler deploy`）

### 複数の宛先へ複製する（まだ有効にしていない）

`REPLICA_TARGETS` に複製先を書き、R2 のイベント通知を Queue に流し、`wrangler.toml` に Queue の consumer を足す。
複製先は `{"id","kind":"r2","binding"}`（同じアカウントの別バケット）か `{"id","kind":"s3","endpoint","bucket","region","accessKeyIdVar","secretAccessKeyVar"}`（他の S3 互換）。
Queue とイベント通知は `wrangler queues create` と `wrangler r2 bucket notification create` で作る。

## ライセンス

MIT（[LICENSE](LICENSE) を参照）
