# claude-warmline

[English](README.md) | **日本語** | [繁體中文](README.zh-TW.md) | [简体中文](README.zh-CN.md)

[![tests](https://github.com/Miguel-Barroso/claude-warmline/actions/workflows/test.yml/badge.svg)](https://github.com/Miguel-Barroso/claude-warmline/actions/workflows/test.yml)
[![version](https://img.shields.io/github/v/tag/Miguel-Barroso/claude-warmline?label=version)](https://github.com/Miguel-Barroso/claude-warmline/tags)
[![license](https://img.shields.io/github/license/Miguel-Barroso/claude-warmline)](LICENSE)

**Claude Code があなたの会話全体を静かに再処理する瞬間を見抜き、避けられる分を防ぎます。**

Claude Code の隠れたコンテキスト/キャッシュ経済のための軽量なオブザーバビリティ:
ステータスライン、監査ツール、そしてオプションのキープウォームポリシー。依存関係は
`python3` と `bash` のみ。外部への送信は一切ありません — すべては Claude Code が
すでにあなたのマシンに記録しているデータから読み取ります。

![3 つの状態のステータスライン: 緑の cache HOT と keep-warm on、黄の cache COLD(rebuilt)、赤の cache COLD(ttl?) と keep-warm off](docs/statusline.svg)

## 30 秒でわかる仕組み

Claude はメッセージ間で何も覚えていません。Enter を押すたびに、Claude Code は
これまでの会話*全体* — システムプロンプト、ツール、読み込んだすべてのファイル、
すべての返答 — を再送信します。長いセッションでは毎ターン 10 万トークン超の入力に
簡単に到達します。

これを現実的なコストに保っているのが、サーバー側の**プロンプトキャッシュ**です。
Claude があなたの会話用にすでに整えた作業場だと考えてください。その作業場が
残っている間、新しいメッセージはそれを通常の入力価格の約 **0.1 倍**で*読み取り*
ます。設営コストは約 **2 倍** — 一度払えば、以降のすべてのターンで償却されます。

問題は、その作業場が**約 1 時間の無操作**で静かに撤去されること。そして会話の
冒頭が書き換えられた瞬間にも即座に消えます(`/compact` は必ずフル再構築を
引き起こします)。昼食から戻って大きなセッションを再開すれば、次のメッセージが
そのすべてを 2 倍の価格で払い直します — 結果が欲しいまさにその瞬間に。

Claude Code はこれを一切表示しません。warmline はそれを可視化し、避けられる部分を
防ぎます。

## クイックスタート

```sh
curl -fsSL https://raw.githubusercontent.com/Miguel-Barroso/claude-warmline/main/install.sh | bash

warmline status              # 何がインストールされ、有効か
warmline keep-warm on        # 任意: 避けられるコールドスタートを防ぐ
```

あとは普段どおり Claude Code を使うだけ — ステータスラインがキャッシュ状態を
ライブで表示します。セッション(あるいは全セッション)の実際のコストを知りたい
ときは:

```sh
warmline-audit               # このセッションをターンごとに
warmline-audit --all         # 全セッションを、漏れの大きい順に
```

[インストールの詳細・フラグ・更新・Windows →](docs/INSTALL.md)

## ラインの読み方

```
Fable 5 | claude-warmline | ctx 43% (168k) | cache HOT | gap 12m | keep-warm on
```

| フィールド | 意味 |
|---|---|
| `ctx 43% (168k)` | コンテキストウィンドウ使用率と、会話中の入力トークン数 |
| `cache HOT` | 直前のリクエストはプロンプトキャッシュから読み取った(緑) |
| `cache HOT (cold in 9m)` | まだ温かいが TTL まで 15 分以内 — 今動くか、再構築を払うか(黄) |
| `cache COLD(rebuilt)` | 直前のリクエストはプレフィックスが冷えており、再キャッシュした(黄) |
| `cache COLD(ttl?)` | *推定*: TTL を超えて静かだったため、キャッシュは失効している(赤) |
| `gap 12m` | このセッションの最後の API ターンからの分数。アイドル時の再描画ではリセットされない |
| `keep-warm on` | [キープウォームポリシー](#keep-warm)が入っているか — `off` は淡色、ブロックが壊れていれば `?` |

正直な注意点が 2 つ。Claude Code がステータスラインに渡す使用量は*直前の*リクエスト
のものなので、`HOT`/`COLD(rebuilt)` は 1 ターン遅れます。また `COLD(ttl?)` は時間に
基づく推定です — だから `?` が付いています。warmline が保証するのは、アイドル時計が
再描画を越えて生き残ることです。だから戻ってきて最初の再描画がすでに
`COLD(ttl?)` を示します — まだ何も支払う前に。

[全フィールド・色・gap の仕組み・トラブルシューティング →](docs/STATUSLINE.md)(英語)

## 冷えて戻ってきたとき: `/compact`、`/clear`、それとも何もしない?

大きなコンテキストでの `COLD(ttl?)` は分かれ道です。キャッシュはもう消えており、
次に何をしようとそのコンテキストは高価な未キャッシュ価格でもう一度処理されます。
問題は、その避けられない 1 回のパスで何を買うかだけです:

- **会話の履歴がまだ必要 → `/compact`。** コンパクションは要約のために会話全体を
  一度読む必要があります。キャッシュが温かければその読み取りは安いのですが、同時に
  2 倍を払って作ったキャッシュを破壊します — だから `HOT` の状態でのコンパクトは
  最悪のタイミングです(コンテキストウィンドウが尽きて選択肢がない場合を除く)。
  キャッシュが冷えていれば、その高価なパスはどのみち次のメッセージで発生します。
  コンパクションはそれを小さな要約の生成に振り向けるだけ — 以後は 10 万トークン超
  ではなく数千トークンをキャッシュして持ち運びます。`/compact` の効果が最も大きい
  のは、まさにキャッシュがすでに死んでいるときです。
- **状態が会話の外に書き出されている → `/clear`。** 必要なものがメモリファイル、
  計画ドキュメント、コードや git 履歴にあるなら、`/clear` は要約パスすら省きます —
  古いコンテキストを読み直す費用は誰も払いません。新しいセッションのプレフィックスは
  システムプロンプト、あなたの CLAUDE.md、メモリインデックスだけ。ファイルは必要に
  なったときにだけ読み直され、10 万トークン超の会話を 1 回要約するよりほぼ常に
  はるかに安上がりです。
- **コンテキストが小さい → 何もしない。** 2 万トークンで冷えても再構築は安いもの。
  ここにあるすべては 10 万トークン超のケースのために存在します。

## お金はどこへ消えたのか

`warmline-audit` はセッションに記録されたすべての API リクエストを採点します —
遅延も推定もありません。`--all` はマシン上の全セッションを**避けられたコールド
トークン**(セッションが避けられない最初の書き込みを除いた、冷えた状態での
再キャッシュ)で順位付けします。あるマシンの 8 週間の履歴からの実出力:

```
$ warmline-audit --all --price 3
145 sessions under /Users/mb/.claude/projects  (13 more without API turns; ttl 60m)

cache health  █████████████████████████░  95% hot  (10,242 of 10,756 turns)
cold events   187  (152 rebuilt, 35 ttl)

start        project                 turns    hot  part  rebuilt   ttl  avoidable cold    premium
08-07 14:30  MimirBlue                 201    189     6        4     2       1,294,770      $7.38
   ⋮
TOTAL                                10756  10242   327      152    35      11,661,736     $66.47

where the cold came from
  unknown             ██████████████████████████  89
  session start       ████████████████  56
  auto-compact        ███████████  36
  inactivity          ████████  28

estimated avoidable premium ~$66.47  (top 5 sessions: $21.36, other 140: $45.12)
```

冷えたターンには、トランスクリプトが証明できる範囲で原因が付きます —
`/compact`、`auto-compact`、`model change`、`inactivity` — 証明できないものは
正直に `unknown`(実際にはプレフィックスのドリフト: 編集された CLAUDE.md、変化した
git の状態、MCP の可否)。ここで起きていることに注目してください。静かなドリフトの
方がコンパクションよりも多くのキャッシュを再構築させています。漏れはたいてい
予想外の場所にあります。

金額はあなた自身のトランスクリプトに記録されたトークン数からの推定であり、
請求データではありません。

[詳しい読み方・判定・原因・`--all`・`--json` →](docs/AUDIT.md)(英語)

## Keep Warm

ここまではすべて*観測*です。Keep Warm は*予防*する任意の半分:
`~/.claude/CLAUDE.md` に置かれる短い指示ブロックで、長く静かな待機の間およそ
50 分ごとに ping するようエージェントに伝えます。結果が返ってくるときには
キャッシュがまだ温かい、というわけです。

```sh
warmline keep-warm on        # グローバル。セッションや更新をまたいで持続
warmline keep-warm status    # ON / OFF / INCONSISTENT (終了コード 0 / 1 / 2)
warmline keep-warm off
```

これは**デーモンではありません** — cron もプロセスも、動作中の Claude Code
セッションの外での通信もありません。バックグラウンドタスクがすでに無料でキャッシュを
温めているときはスキップし、小さなコンテキストもスキップし、作業が再開した瞬間に
停止し、約 10 時間で諦めます。ping のコストはコンテキストの約 0.1 倍、それが防ぐ
再構築は約 2 倍です。

[何であり何でないか・動作できない条件・利用規約の検討 →](docs/KEEP-WARM.md)(英語)

## どこで動くか

| フロントエンド | ステータスライン | `warmline-audit` | keep-warm |
|---|---|---|---|
| ターミナル CLI | ✅ | ✅ | ✅ |
| デスクトップアプリ(ローカルの Code タブ) | ❌ | ✅ | ✅ |
| VS Code / JetBrains のパネル | ❌ | ✅ | ✅ |
| クラウド / Cowork セッション | ❌ | ❌ | — |

グラフィカルなフロントエンドはカスタムステータスラインを描画しません
([要望チケット](https://github.com/anthropics/claude-code/issues/41456))。
ただし同じエンジンを動かし、同じ `~/.claude` を共有し、同じトランスクリプトを
書き出すので、監査ツールとキープウォームポリシーはそのまま機能します。デスクトップ
アプリでゲージも見たいときは、統合ターミナルで `claude` を起動してください。

[完全な対応表と検証方法 →](docs/SURFACES.md)(英語)

## モデルではなく実測

- **50 分アイドル: 温かい。70 分: 冷たい。** クリーンルームでの 2 アーム計測で、
  50 分後のプローブは 71,312 トークンのプレフィックス全体を読み戻し、70 分後は
  45,033 トークンを書き直しました。1 時間の TTL は実在し、読み取りが TTL を
  更新します — ping が効く理由そのものです。
- **バックグラウンド作業はキャッシュを無料で温める。** 約 9 分ごとのタスク通知が、
  30 万トークンのコンテキストを 4 時間ホットに保ちました(1 回の起床あたり
  キャッシュ書き込みは約 400 トークン)。だから keep-warm はこのケースをスキップ
  します。
- **蓋を閉じたマシンではどんなウェイクアップも生き残らない。** 13 時間・260 ターンの
  セッションで唯一の TTL 失効は、マシンが眠っていた 6 時間の夜間沈黙のあとでした。
- **プレフィックスの安定性は TTL と同じくらい重要。** ドリフトするシステム
  プロンプト(編集された CLAUDE.md、変化した git の状態、MCP の可否)は分岐点より
  後をすべて再キャッシュさせ、どんな ping も救えません。

[数値・手法・再現方法 →](docs/MEASUREMENTS.md)(英語)

## ドキュメント

詳細ドキュメントは英語のみです。

| | |
|---|---|
| [Statusline](docs/STATUSLINE.md) | 全フィールド、色、gap の仕組み、トラブルシューティング |
| [Audit](docs/AUDIT.md) | 判定、原因の帰属、`--all`、"avoidable" の定義 |
| [Keep Warm](docs/KEEP-WARM.md) | ポリシー、その限界、規約の検討 |
| [Where it works](docs/SURFACES.md) | ターミナル、デスクトップ、IDE、SSH、クラウド |
| [Install](docs/INSTALL.md) | インストール、更新、アンインストール、設定、Windows、テスト |
| [Measurements](docs/MEASUREMENTS.md) | すべての主張の裏付けとなる実測 |
| [Changelog](CHANGELOG.md) | タグ付きリリース |

## ライセンス

[MIT](LICENSE)

## コーヒーをおごる ☕

BTC: `bc1qjsvtd3dd44llyu4rwz2ucl4kp9wd9kvpsj6tk5`
