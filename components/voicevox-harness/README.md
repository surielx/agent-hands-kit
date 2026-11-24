# voicevox-harness — VOICEVOX を GUI なしで操作するハーネス

VOICEVOX のエンジン API（`http://127.0.0.1:50021`）を直接叩いて日本語音声を合成する道具です。GUI エディタの編集内容（アクセント句・モーラ別ピッチ・長さ）はすべて AudioQuery JSON の数値なので、API 経由なら座標操作なしで正確に扱えます。

## なぜ GUI ではなく API か（実運用で学んだこと）

- VOICEVOX エディタ（Electron）のモーラ別スライダーは、合成入力（ドラッグ/ホイール/キー）を受け付けず、エージェントが値を上書きできませんでした
- アクセント画面のグラフ付近のクリックは、アクセント句の結合/分割トグルに当たることがあり、誤操作のリスクがあります
- エージェントは音を聞けないので、聞き取りの代わりに**出力 WAV の基本周波数（F0）を実測して句ごとの上昇/下降を検証**します

## 処理の流れ

1. エンジンが未起動なら自動起動（エディタ同梱の `run.exe`）
2. テキストを文に分け、`audio_query` でアクセント/ピッチ計画を取得して表示
3. エンジンの素の抑揚で合成（**既定ではピッチを書き換えません**。疑問文の語尾を一律に持ち上げる自動ルールは、実運用の試聴 A/B で「不自然」と判定されたため、`-Rules` の明示指定時のみ・弱い補正だけに格下げ済み）
4. 出力 WAV を F0 実測し、句ごとの first/last ピッチと傾向（RISE / fall / flat）を報告

## 使い方

前提：VOICEVOX がインストール済みであること。Python 3（numpy + soundfile が必要）。

```powershell
# 配置（例）
#   vv_harness.py と vv-say.ps1 を同じフォルダに置く
#   その フォルダに .venv を作るか、環境変数 VV_PYTHON で Python を指す

.\vv-say.ps1 -Text "はじめまして。私の声、聞こえてますか？" -Speaker 10
# → 計画と検証レポートを標準出力に、最後に VV_OK <wavパス>
```

- `-Speaker` は VOICEVOX のスタイル ID（例：10 = 雨晴はう ノーマル）
- `-TextFile` で UTF-8 ファイルから本文を渡すこともできます（シェルの文字コード問題回避）
- 成否は最終行マーカー `VV_OK` / `VV_FAILED <reason>` で判定します

## 実例

このハーネスは、AI エージェントが CAD（SolidCraft）を操作して作ったデモ動画に、テロップへ合わせた解説音声を付ける作業で実運用されました。録画・音声生成・動画合成まで、すべてエージェントが実行しています。公式サイトの「実例」セクションにスクリーンショット付きで掲載しています。

---

*English summary: A harness that drives the VOICEVOX text-to-speech engine through its HTTP API instead of the GUI — because the editor's per-mora sliders do not accept synthetic input and its accent graph is click-sensitive. It prints the accent/pitch plan, synthesizes with the engine's native prosody by default, and verifies the result by measuring the output's F0 contour (an agent cannot listen, so it measures). Result markers: `VV_OK` / `VV_FAILED`.*
