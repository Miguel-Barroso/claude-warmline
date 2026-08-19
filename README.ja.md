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

![3つの状態の warmline ステータスライン: 緑の cache HOT、黄色の cache COLD(rebuilt)、赤の cache COLD(ttl?)](docs/statusline.svg)

## 30秒でわかる版

Claude はメッセージ間で何も記憶していません。エンターを押すたびに、Claude Code は
それまでの会話*全体* — システムプロンプト、ツール、読み込んだすべてのファイル、
すべての返答 — を再送信します。長いセッションでは、毎ターン優に 100k+ トークンの
入力になります。

これを手頃なコストにしているのが、サーバー側の**プロンプトキャッシュ**です。Claude が
あなたの会話のためにすでに整えてある作業場のようなものだと考えてください: 作業場が
立っている間、新しいメッセージは通常の入力価格の約 **0.1×** でそれを*読み取り*ます。
設営には約 **2×** かかります — 一度だけ支払い、以後のすべてのターンで償却される
コストです。忙しいセッションが 200k コンテキストでも速く安く感じられるのはこのためです。

落とし穴: この作業場は**約1時間の無活動**で静かに解体されます。昼食後に大きな
セッションへ戻ると、次のメッセージがそのすべてを 2× の料金で建て直します — まさに
結果が欲しかったその瞬間にです。また、会話の冒頭が書き換えられると、アイドル時間が
*なくても*解体されます: `/compact` は作業場全体を再編成するため、常に完全な建て直しを
引き起こします。

Claude Code はこうした情報を一切表示しません。warmline はそれを可視化し — 避けられる
分を防ぐ手助けをします。

## クイックスタート

```sh
curl -fsSL https://raw.githubusercontent.com/Miguel-Barroso/claude-warmline/main/install.sh | bash

warmline keep-warm on        # optional: prevent avoidable cold starts
warmline keep-warm status    # is it on?
```

あとは Claude Code を通常どおり使ってください — ステータスラインがキャッシュの状態を
ライブで表示します。あるセッション（またはすべてのセッション）が実際にいくら
かかったのかを知りたくなったら:

```sh
warmline-audit               # this session, turn by turn
warmline-audit --all         # every session, ranked by where the money leaked
```

## warmline が答える問い

| | 問い |
|---|---|
| **ステータスライン** | いま何が起きているのか？（`cache HOT` / `COLD`、ライブ表示） |
| **`warmline-audit`** | このセッションで何が起きたのか、ターンごとに？ |
| **`warmline-audit --all`** | 全セッションを通じて、どこでお金が漏れているのか？ |
| **原因帰属** | *なぜ*キャッシュはコールドになったのか — アイドル、`/compact`、ドリフト？ |
| **キープウォーム**（オプション） | 避けられるコールドスタートを防げるか？ |

## インストール

```sh
curl -fsSL https://raw.githubusercontent.com/Miguel-Barroso/claude-warmline/main/install.sh | bash
```

またはチェックアウトから:

```sh
git clone https://github.com/Miguel-Barroso/claude-warmline.git
cd claude-warmline
./install.sh
```

何がどこに配置されるか: `statusline.py` は `~/.claude/warmline-statusline.py` へ
コピーされ、`~/.claude/settings.json` に組み込まれます（先にバックアップされます。
既存のカスタムステータスラインが `--force` なしに置き換えられることはありません）。
`warmline` と `warmline-audit` の両コマンドは `~/.local/bin/` へ（`WARMLINE_BIN_DIR`
で上書き可能）、キープウォームのポリシーテキストは `~/.claude/warmline-keep-warm.md`
へ。Claude Code は通常数秒以内にステータスラインを反映します — 反映されない場合は
セッションを再起動してください。

`~/.local/bin` が `PATH` にない場合、インストーラーはその旨を伝え、追加すべき正確な
行（`export PATH="$HOME/.local/bin:$PATH"`）を表示します — シェルの起動ファイルを
インストーラー自身が編集することは決してありません。

| フラグ | 効果 |
|---|---|
| `--keep-warm` | [`warmline keep-warm on`](#キープウォーム) のインストール時ショートハンド |
| `--force` | warmline 以外の既存ステータスラインを置き換えます |
| `--uninstall` | ポリシーブロックを含め、インストーラーが追加したすべてを削除します |
| `--help` | 使い方 |

必要なのは `python3`（標準ライブラリのみ）と `bash` です。`curl` 形式でフラグを
渡すには: `curl -fsSL …/install.sh | bash -s -- --keep-warm`。

**インストーラーは warmline をインストールします。`warmline` コマンドがそれを制御
します。** いつでも、「このマシンで warmline は何をしているのか？」には1つの
コマンドが答えます:

```
$ warmline status
claude-warmline status  (config: /Users/mb/.claude)
  statusline  ON   /Users/mb/.claude/warmline-statusline.py
  keep-warm   OFF  (enable: warmline keep-warm on)
  auditor     ON   /Users/mb/.local/bin/warmline-audit
  ttl         60m (default)
```

## ラインの読み方

| フィールド | 意味 |
|---|---|
| `ctx 43% (168k)` | コンテキストウィンドウの使用率と、会話内の入力トークン数 |
| `cache HOT` | 直前のリクエストがプロンプトキャッシュから読み取りました（緑） |
| `cache HOT (cold in 9m)` | まだウォームですが、アイドルの空白が TTL まで15分以内に迫っています — 今動くか、再構築コストを支払うかです（黄） |
| `cache COLD(rebuilt)` | 直前のリクエストがコールドなプレフィックスに遭遇し、再キャッシュしました（黄） |
| `cache COLD(ttl?)` | *推論*: セッションが TTL より長く沈黙しているため、（古い）usage フィールドの内容にかかわらずキャッシュは失効しています（赤） |
| `cache ?` | usage フィールドが利用できません |
| `gap 12m` | このセッションの最後の API ターンからの経過分数（5分から表示。アイドル時の再描画ではリセットされません） |

色はデフォルトで有効です（Claude Code はステータスラインで ANSI をレンダリングします）。
無効にするには `NO_COLOR` または `WARMLINE_NO_COLOR` を設定してください。

正直な制限事項: Claude Code がステータスラインに渡すのは*直前の*リクエストの usage の
数値なので、`HOT`/`COLD(rebuilt)` は1ターン遅れます。また `COLD(ttl?)` は時間ベースの
推論です — `?` が付いているのはそのためです。ラインはプル型でもあります: スクリプトは
Claude Code が再描画するときにしか実行されないため、マシンがスリープしている間は、
最後にレンダリングされたライン — その時点ではすでに誤りになっていることの多い `HOT` — が
画面に凍りついたまま残ります。warmline が保証するのは、アイドル時計が再描画をまたいで
生き残ることです: リセットするのは実際の API ターンだけなので、戻ってきた後の最初の
再描画は — まだ何も支払っていない時点で — すでに `COLD(ttl?)` を示します。空白時間は
セッションごとに追跡されるため（`~/.claude/warmline-state/` のスタンプファイル）、
並行するセッションが互いのアイドル時計をリセットすることはありません。

実用上の使い方: 大きな `ctx` での `COLD(ttl?)` は、方針転換に最も安く済む瞬間を
示しています — [コールドで戻ってきたら](#コールドで戻ってきたら-compact-か-clear-かそれとも何もしないか)を参照してください。

## 過去セッションの監査

```sh
warmline-audit                      # latest session of the current project
warmline-audit path/to/session.jsonl
warmline-audit --ttl 5 --json       # short-TTL setups, machine-readable
warmline-audit --price 3            # add dollar estimates, given your
                                    # model's base input price per MTok
warmline-audit --all --price 3      # every session on this machine,
                                    # ranked by estimated avoidable premium
```

（`~/.local/bin/` にインストールされます。チェックアウトからは `./warmline-audit`。
`warmline audit …` も同じものです。）

（構造上1ターン遅れる）ステータスラインと異なり、監査は決定的な情報源です: 記録された
すべての API リクエストを採点します。実際のセッション:

```
$ warmline-audit --price 3
~/.claude/projects/…/0f83878e.jsonl  (ttl 60m)
time                gap   cache read   cache write  verdict
08-17 22:27:52       2m       68,999        20,349  HOT
08-17 22:28:30      <1m       89,348         9,484  HOT
   ⋮
08-17 23:27:21       8m            0        40,761  COLD(rebuilt)  <- /compact
08-17 23:27:53      <1m       18,873        43,431  PARTIAL
   ⋮
08-18 03:50:34      <1m      318,730           449  HOT
08-18 10:02:45    6h12m            0        58,427  COLD(ttl)  <- inactivity+compact
08-18 10:02:53      <1m       58,427         1,123  HOT
   ⋮
08-18 12:04:50      <1m      173,939           746  HOT

cache health  ██████████████████████████  98% hot  (255 of 260 turns)

260 API turns; HOT 255  PARTIAL 3  COLD(rebuilt) 1  COLD(ttl) 1
causes: inactivity+compact 1  /compact 1
tokens re-cached while cold: 99,188   read from cache: 45,926,103
(a cold re-cache bills ~2x base input; a warm wake reads at ~0.1x)
at $3/MTok base input: the cold re-caches cost ~$0.57 more than warm reads of the same tokens would have; cache reads billed ~$13.78
estimated avoidable premium ~$0.57
```

上から順に読むと:

- **各行が1つの API リクエストです。** `gap` はその前のアイドル時間、`cache
  read`/`cache write` はキャッシュから読み取った、あるいはキャッシュへ再書き込みした
  トークン数です。
- `/compact` の行は、原因が証明された **`COLD(rebuilt)`** です: 構造化された
  コンパクト境界マーカーが、トランスクリプト上でこの行の直前に存在します。アイドル
  時間はゼロ — プレフィックスの書き換えだけでキャッシュが死にました。直後の
  `PARTIAL` も典型的です: コンパクションは共有プレフィックスの先頭をウォームのまま
  残すことが多いため、次のターンは一部をキャッシュから読み戻しつつ、残りを
  再書き込みします。
- `6h12m` の行が高くついた行です: 夜間の沈黙でキャッシュが失効し、朝一番の
  メッセージが 58k トークンを 2× の料金で再書き込みしました。その空白の中には
  コンパクションも*同時に*存在するため、監査ツールは推測せずに
  **`inactivity+compact`** とラベル付けします — どちらでも再構築を説明できるからです。
- **cache health バー**は、ホットに走ったターンの割合です。その下に判定の集計、
  そして各コールドターンが*なぜ*起きたのかが続きます。（セッションの最初の
  キャッシュ書き込みは `session start` と採点され、回避可能には決して数えません。
  このセッションはまだウォームなキャッシュへ再開合流したため、それ自体がありません。）
- 最終行の **estimated avoidable premium** は、*潜在的に*回避可能なコールド
  再キャッシュが、同じトークンのウォームな読み取りと比べて*余分に*かかったコスト
  です（コールドな再キャッシュは約 2× で課金され、置き換えられたウォームな読み取りは
  約 0.1× のはずでした — 差は 1.9× です）。記録されたトークン数からの見積もりであり、
  課金データでは決してありません —
  [「回避可能」の正確な意味](#お金はどこで漏れているのか---all)。

原因は当て推量ではなく帰属です: `/compact` と `auto-compact` はトランスクリプト内の
構造化マーカーから、`model change` は記録されたモデルから来ます。
`inactivity+compact` はどちらでも説明がつく曖昧なケースのラベルで、それ以外はすべて
正直に `unknown` です — 実際にはその大半が、トランスクリプトでは証明できない
プレフィックスドリフト（編集された CLAUDE.md、変化した git の状態、MCP の可用性）です。

### お金はどこで漏れているのか？ `--all`

`--all` は `~/.claude/projects`（または指定したディレクトリ）配下のすべての
セッションを監査し、セッションごとに1行を**回避可能なコールドトークン**でランク付け
して出力します — この言葉はここでは正確な意味を持ち、出力のすぐ下で定義します。
このマシンの8週間の履歴からの実際の出力:

```
$ warmline-audit --all --price 3
145 sessions under /Users/mb/.claude/projects  (13 more without API turns; ttl 60m)

cache health  █████████████████████████░  95% hot  (10,242 of 10,756 turns)
cold events   187  (152 rebuilt, 35 ttl)

start        project                 turns    hot  part  rebuilt   ttl  avoidable cold    premium
08-07 14:30  MimirBlue                 201    189     6        4     2       1,294,770      $7.38
08-08 10:57  MimirBlue                  66     58     1        4     3         814,630      $4.64
08-11 12:03  MimirBlue                  48     40     1        4     3         624,201      $3.56
   ⋮
TOTAL                                10756  10242   327      152    35      11,661,736     $66.47

causes: inactivity 28  inactivity+compact 7  /compact 7  auto-compact 36  model change 3  unknown 89  session start 56

where the cold came from
  unknown             ██████████████████████████  89
  session start       ████████████████  56
  auto-compact        ███████████  36
  inactivity          ████████  28
  /compact            ██  7
  inactivity+compact  ██  7
  model change        █  3

avoidable cold = tokens re-cached cold, excluding each session's unavoidable first write
premium = estimated avoidable premium of those re-caches vs warm reads (1.9x $3/MTok);
an estimate from recorded token counts, not billing data

estimated avoidable premium ~$66.47  (top 5 sessions: $21.36, other 140: $45.12)
```

**「回避可能」の正確な意味。** どのセッションも、最初のキャッシュ書き込みには必ず
支払わなければなりません: 何かを安く読み戻せるようになる前に、会話は一度キャッシュ
される必要があります。warmline はこれを決して数えません。*回避可能*として数えるのは、
その時点より**後**にコールドで再キャッシュされたすべてのトークンです — TTL 失効、
コンパクション、プレフィックスドリフトによる再構築で、タイミングが違えば（キープ
ウォームの ping、より早い意図的な `/compact`、安定したプレフィックス）防げた*かも
しれない*ものです。したがってこの数字は「さらされていた額」の見積もりであり、実際に
無駄になったお金ではありません: 一部は実際上防ぎようがなく（ラップトップのスリープ中
の TTL 失効も「回避可能」に数えられますが、ping は発火しようがありませんでした）、
すべてはあなたのトランスクリプトに記録されたトークン数から計算されます — warmline は
Anthropic があなたのアカウントに実際に請求した額を見ることはなく、見ることも
できません。

読み方: 上位にあり `ttl` のカウントが大きいセッションはキープウォームの候補です —
席を外したことで失われたお金です。`rebuilt`/`unknown` のカウントが大きい場合は
プレフィックスの揺れを意味します: 何かがターン間で会話プレフィックスを書き換えて
います。`auto-compact` が多いのは、セッションが日常的にコンテキスト上限に激突して
いることを意味し、そこではより早く意図的にコンパクトする（下記参照）ほうが安く
済みます。最終行の分割は集中度です: 漏れは少数の大惨事なのか、それとも薄く広がって
いるのか？このマシンでは薄く広がっています — 上位5セッションはプレミアムの3分の1
しか占めておらず、サイレントなプレフィックスドリフト（`unknown 89`）がコンパクション
（43）よりも多くのキャッシュを再構築したという正直な見出しと符合します。漏れは
予想した場所にあることがめったにありません。

パイプや CI の出力はプレーンなままで（バーと色は TTY でのみ有効）、`--json` は
変更されておらず機械可読です。

## キープウォーム

ここまではすべて*観測*です。キープウォームは*防止*を担うオプションの半身で、
戻ってくるつもりの長い待機の間、キャッシュの失効を防ぎます。

```sh
warmline keep-warm on        # turn it on (once)
warmline keep-warm status    # is it on?
warmline keep-warm off       # turn it off
```

これだけです。グローバルであり（`~/.claude/CLAUDE.md` の1ブロック）、すべての
プロジェクトに適用され、セッションやインストーラーの更新をまたいで持続します —
一度設定すれば忘れてかまいません。（`./install.sh --keep-warm` はインストール時に
同じ有効化を実行します。`--uninstall` は他のすべてと一緒にこれも削除します。）

```
$ warmline keep-warm status
keep-warm  ON
  scope    global -- applies to every project  (block in /Users/mb/.claude/CLAUDE.md)
  policy   intact
```

`status` は状態ファイルを決して信用しません — 毎回あなたの実際の CLAUDE.md を
読みます。ブロックを手で消せば OFF と報告し、ブロックが半分だけ残っていれば、
偽の ON ではなく INCONSISTENT を修正方法とともに報告します。スクリプトからは
終了コードが答えです: `0` はオン、`1` はオフ、`2` は不整合。

**その正体:** マーカーで区切られた短い指示ブロック（[`keep-warm.md`](keep-warm.md)）
で、アクティブなセッション中にエージェントがこれに従います。コンテキストが大きい
状態で約45分を超えると見込まれるバックグラウンド作業を開始したら、約50分後の
ウェイクアップをスケジュールします。ウェイク時に作業がまだ実行中なら再スケジュール
し、そうでなければ通常どおり続行します — 結果はホットなキャッシュに着地します。
ping 1回のコストはキャッシュ読み取りクォータでコンテキストの約 0.1×、対して
コールドの再書き込みは約 2× なので、*戻ってくるなら*おおよそ10〜12時間までの
アイドルに対して元が取れます。

**キープウォームがそうでないもの:**

- **デーモンではありません。** バックグラウンドプロセスも cron もなく、実行中の
  Claude Code セッションの外でリクエストが発生することはありません。Claude Code が
  動いていなければ、何も動きません。
- **常時オンではありません。** ローカルのバックグラウンドタスクが進行中のとき
  （その通知が無料でキャッシュをウォームに保ちます — 下で実測）や、コールドに
  なっても安く済む小さなコンテキストでは、意図的に*スキップ*します。
- **待機より長生きしません。** ウェイクアップは作業が再開した瞬間に削除され、
  1つの待機は約12回の再スケジュール（約10時間）で打ち切られます — それを超えると、
  ping のコストが防ぐはずの再構築を上回ります。

**動作できない場面:** ホストマシンのスリープ中はウェイクアップは発火できません
（macOS では `caffeinate -is` が計画的な待機を起こしたままにします）。一部の
Claude Code ビルドでは `ScheduleWakeup` が存在しないか制限されています — その場合
エージェントは定期的なスケジュール済みプロンプト（`/loop 50m <ping>`）に
フォールバックするか、ブロックは単に不活性になります。そしてこれはコードではなく
指示です: エージェントが従い損ねる可能性はあります。実際に機能したかを検証する
手段が監査です。

**これは Anthropic の規約の範囲内か？** 推測ではなく調査しました。キープウォームが
依拠するメカニズムは文書化された製品挙動です: Anthropic の
[プロンプトキャッシュのドキュメント](https://platform.claude.com/docs/en/build-with-claude/prompt-caching)
は、キャッシュは「キャッシュされたコンテンツが使用されるたびに追加コストなしで
更新される」と述べており、API 利用については定期的なプリウォームリクエストを明示的に
推奨しています。キープウォームの ping は、実行中のセッション内の通常の課金対象
リクエストです: あなた自身のクォータを消費し（多くの場合、置き換えるコールドな
再構築より*少なく*）、何も迂回しません。重要な境界は反対側にあります — Anthropic の
週次制限は、Claude Code を24時間365日バックグラウンドで走らせ続けるアカウントを
抑制するために存在します。だからこそこのポリシーは設計として有界です: 戻ってくる
つもりの本物の待機の間だけ、最大でも約50分に1回だけ ping し、ウォームが無料で
手に入るときはスキップし、作業が再開した瞬間に停止し、約10時間で打ち切り、決して
デーモンにはなりません。この境界を緩めないでください。正直な未知が1つ残ります:
コンシューマー向け Claude Code セッション内のスケジュールされた ping が、
サブスクリプションプランの前提とする「通常の個人利用」に数えられるのかどうかは、
私たちが見つけられた範囲のどこにも書かれていません — この特定の使い方に対する
Anthropic の正確な立場は不明です。これは Anthropic がキープウォームを承認している
という意味ではありません — 破っているルールが見つからなかったこと、そして
Anthropic が対処してきた挙動から遠く離れているよう設計したことを意味します。

## コールドで戻ってきたら: `/compact` か `/clear` か、それとも何もしないか？

大きなコンテキストでの `COLD(ttl?)` は分かれ道です。キャッシュはすでに失われて
います。次に何をしようと、そのコンテキストは高価な非キャッシュ料金でもう一度処理
されます。問われるのはただ一つ、その避けられない1パスで何を手に入れるかです:

- **会話履歴がまだ必要 → `/compact`。** コンパクションは要約のために会話全体を
  一度読む必要があります。ウォームなキャッシュ上ならその読み取りは安価です — しかし
  同時に、2× を支払って構築したキャッシュを破壊してしまいます。`HOT` の間に
  コンパクトするのが最悪のタイミングである理由がこれです（コンテキストウィンドウが
  尽きて選択肢がない場合を除きます）。コールドなキャッシュ上では、その高価なパスは
  どのみち次のメッセージで発生するはずでした — コンパクションはそれを小さな要約の
  生成に振り向けるだけです。以後は 100k+ ではなく数千トークンをキャッシュして
  持ち運ぶことになります。`/compact` が最も効果を発揮するのが、キャッシュが
  すでに死んでいるまさにそのときです。
- **状態が会話の外に書き留めてある → `/clear`。** 続行に必要なものがメモリファイル、
  計画ドキュメント、あるいはコードと git 履歴にあるなら、`/clear` は要約パスすら
  スキップします — 古いコンテキストを読むための支払いは二度と発生しません。新しい
  セッションのプレフィックスはシステムプロンプト、あなたの CLAUDE.md、メモリ
  インデックスだけで、ファイルは関連が生じたときにのみ再読み込みされます。それは
  100k+ の会話に対する要約1パスよりほぼ常にはるかに安く済みます。
- **コンテキストが小さい → 何もしない。** 20k トークンでコールドになっても再構築は
  安価です。ここにあるすべては 100k+ のケースのために存在します。

## 実測したこと（モデル計算ではありません）

上記の主張はすべて実際のトランスクリプトに対して検証可能です — Claude Code は
すべての API ターンの `cache_read_input_tokens` と `cache_creation_input_tokens` を
記録しており、`warmline-audit` がそれを採点します。実際の13時間のオーケストレーション
セッション（2026-08-18、約 300k コンテキスト、バックグラウンド CI ウォッチャー付きの
マージキュー見守り）から:

- **260 API ターン: 255 HOT、1 COLD(rebuilt)、1 COLD(ttl)** — キャッシュから 45.9M
  トークンを読み取り、コールドで再キャッシュされたのはわずか 99k トークンでした。
- 約9分ごとに届くバックグラウンドタスク通知が、**1回のウェイクあたり約400トークンの
  キャッシュ書き込み**で4時間連続キャッシュをホットに保ちました（その間、読み取りは
  150k から 317k に増加）。**バックグラウンド処理が進行中なら、その通知が無料で
  キャッシュをウォームに保ちます** — ポリシーは不要です。
- 唯一の `COLD(ttl)` は夜間6時間の沈黙の後に発生しました — マシンがスリープしていた
  ため、何も発火できませんでした。**閉じた蓋を生き延びるスケジュール済みウェイク
  アップはありません**（macOS では、計画的な長い待機に対する回避策は `caffeinate` です）。
- 唯一の `COLD(rebuilt)` は `/compact` の後に発生しました: アクティビティから数分
  以内の 58k トークンの完全な再キャッシュです。プレフィックスの無効化と TTL 失効は
  別の障害モードであり、ステータスラインが両者を区別しているのはまさにそのためです。
- ヘッドレスプローブが TTL バケットを裏付けています: Claude Code は `ephemeral_1h`
  （1時間の TTL）でキャッシュを書き込み、再開されたセッションはプレフィックス全体を
  読み戻します（参照プローブでは読み取り 33,614 トークン、書き込み 56 トークン）。
- TTL の境界そのものも、クリーンルームの2アーム実験（隔離されたヘッドレスセッション、
  MCP サーバーなし、凍結された環境）で測定しました: 完全な沈黙の **50分** 後、
  プローブは 71,312 トークンのプレフィックス全体をキャッシュから読み取り、書き込みは
  わずか 56 トークンでした。**70分** 後には、同一のセッションがキャッシュの消失に
  遭遇し、45,033 トークンすべてを再書き込みしました。50分でウォーム、70分でコールド —
  1時間の TTL は実在し、キープウォームの ping 間隔（約50分）はその内側に安全に
  収まっています。
- コールド側のアームは、ping が効く*理由*も実証しました: **読み取りは TTL を更新
  します**。そのプローブでは共有システムブロックがまだウォームでした。もう一方の
  アームが20分前にそのブロックを読み取っていたからです。キープウォームの ping は、
  まさにこの更新をプレフィックス全体に適用するものです。
- このマシンの全履歴（8週間で145セッション）に対して、`warmline-audit --all` は
  Sonnet の基本価格で回避可能なプレミアムの合計を **約$66** と見積もり、キャッシュ
  再構築のうち43件をコンパクションに、**89件を原因不明のプレフィックスドリフト**に
  帰属させました。漏れは予想した場所にあることがめったにありません。
- 同じ実験を意図的にダーティな条件で行った先行の実行では、より捉えにくい障害モードが
  浮かび上がりました: ヘッドレスの `--resume` はシステムプロンプト全体を再生成する
  ため、ターン間の git ステータスのドリフト、MCP サーバーの可用性、編集された
  CLAUDE.md がプレフィックスを静かに分岐させ、分岐点以降のすべてが正規価格で
  再キャッシュされます。**プレフィックスの安定性は TTL と同じくらい重要です**:
  ターン間でプレフィックスが揺れ動くセッションは、どんなキープウォーム ping にも
  救えません。

## 設定

| 環境変数 | デフォルト | 意味 |
|---|---|---|
| `WARMLINE_TTL_MIN` | `60` | プロンプトキャッシュの TTL（分）（短い TTL の構成では `5` を設定） |
| `WARMLINE_STATE_DIR` | `~/.claude/warmline-state` | スタンプ/状態ディレクトリ |
| `WARMLINE_BIN_DIR` | `~/.local/bin` | インストーラーが `warmline` と `warmline-audit` コマンドを配置する場所 |
| `WARMLINE_NO_COLOR` | 未設定 | 設定されている場合（または `NO_COLOR`）、ANSI カラーなしのプレーン出力 |
| `WARMLINE_FORCE_COLOR` | 未設定 | 設定されている場合、パイプ時でも監査出力に色を付けます |
| `WARMLINE_DEBUG` | 未設定 | 設定されている場合、検査用に最後の生のステータスラインペイロードを保持 |

これらは Claude Code を起動する環境、または `~/.claude/settings.json` の `env`
ブロックで設定してください。`WARMLINE_TTL_MIN` はステータスラインと `warmline-audit`
の両方で有効です。

## 互換性と更新

Claude Code **2.1.233**（執筆時点の最新）で検証済みです。ステータスラインの JSON
フィールドは実際のハーネスペイロードに対して確認し、`warmline-audit` はこのマシンに
存在するすべてのトランスクリプト形式 — Claude Code バージョン **2.1.181 から
2.1.233**、145セッション、不正なエントリはゼロ — をパースします。既知の形式の癖が
1つ処理されています: 一部のバージョンは assistant エントリの約28%で `requestId` を
省略するため、監査は `message.id` で API リクエストを重複排除します。

**更新:** インストーラーがアップデーターです。同じ `curl | bash` のワンライナー
（または pull したチェックアウトから `./install.sh`）を再実行してください — 自分自身の
ステータスライン、`warmline` コマンド、監査ツールを認識して `--force` なしでその場で
置き換え、`settings.json` は実行のたびにバックアップされ、キープウォームのオン/オフの
選択はそのまま維持されます。タグ付きリリースの変更は [CHANGELOG.md](CHANGELOG.md) が
記録しています。

**Windows:** ステータスラインと監査ツールは純粋な標準ライブラリの Python であり、
OS を問いません。bash なのはインストーラーとテストスイートだけです。手動インストール:

1. `statusline.py` を `%USERPROFILE%\.claude\warmline-statusline.py` にコピーします
   （必要なら `warmline-audit` も任意の場所に）
2. `%USERPROFILE%\.claude\settings.json` で
   `"statusLine": {"type": "command", "command": "python C:\\Users\\you\\.claude\\warmline-statusline.py"}`
   を設定します
3. 監査ツールは `python warmline-audit [args]` として実行します

`warmline` コマンドも bash なので、Windows ではキープウォームを手で切り替えて
ください — `%USERPROFILE%\.claude\CLAUDE.md` のマーカーで区切られたブロック
（テキストは [`keep-warm.md`](keep-warm.md)）を追加または削除します — あるいは
WSL / Git Bash を使ってください。ANSI カラーは Windows Terminal で問題なく
レンダリングされます。テスト済みの `install.ps1` は歓迎されるコントリビューション
です — このプロジェクトの哲学に沿って、テストできないものは出荷しません。

## テスト

```sh
./test.sh
```

代表的なステータスラインペイロード（ホット、コールド再構築、TTL 失効、疎な入力、
ガベージ、並行セッションの分離、アイドル時の再描画で時計がリセットされないこと、
新しいターンによる TTL 推論の上書き、失効カウントダウン、ANSI カラー）をスクリプトに
対してリプレイします。さらに、`--price` の見積もり、すべてのコールド原因の帰属、
TTY とパイプでの整形の違いを含めて合成トランスクリプトを `warmline-audit` に対して、
合成のマルチプロジェクトコーパスを `--all` に対して検証します。そして `warmline`
CLI のキープウォーム状態遷移（on→on、off→off、不正な形のブロックが偽の ON では
なく正直に報告されること）を、無関係な CLAUDE.md の内容がすべての操作を生き延びる
ことの確認、およびクリーンインストールで `warmline` コマンドが実際に配置されることの
チェックとあわせて検証します。同じスイートがプッシュのたびに CI で実行されます。

## ライセンス

[MIT](LICENSE)

## コーヒーをおごる ☕

BTC: `bc1qjsvtd3dd44llyu4rwz2ucl4kp9wd9kvpsj6tk5`
