# claude-warmline

[English](README.md) | [日本語](README.ja.md) | **繁體中文** | [简体中文](README.zh-CN.md)

[![tests](https://github.com/Miguel-Barroso/claude-warmline/actions/workflows/test.yml/badge.svg)](https://github.com/Miguel-Barroso/claude-warmline/actions/workflows/test.yml)
[![version](https://img.shields.io/github/v/tag/Miguel-Barroso/claude-warmline?label=version)](https://github.com/Miguel-Barroso/claude-warmline/tags)
[![license](https://img.shields.io/github/license/Miguel-Barroso/claude-warmline)](LICENSE)

**看見 Claude Code 什麼時候悄悄重新處理你的整段對話 — 並防止其中可避免的部分。**

針對 Claude Code 隱藏的上下文／快取經濟學的輕量級可觀測性工具：
一條狀態列、一個稽核工具，以及一套可選的 keep-warm 保溫策略。除了
`python3` 和 `bash` 之外沒有任何相依套件；不會回傳任何資料 —
一切都讀自 Claude Code 本來就記錄在你機器上的資料。

![warmline 狀態列的三種狀態：綠色的 cache HOT、黃色的 cache COLD(rebuilt)、紅色的 cache COLD(ttl?)](docs/statusline.svg)

## 30 秒版本

Claude 在訊息與訊息之間不會記得任何事。每次你按下 enter，
Claude Code 都會重新送出至今的*整段*對話 — 系統提示、工具、
它讀過的每一個檔案、每一則回覆。在長時間的工作階段裡，這輕易就是
每一輪 100k+ token 的輸入。

讓這一切負擔得起的是伺服器端的**提示快取**。把它想成 Claude
已經為你的對話佈置好的工作區：只要工作區還在，每則新訊息就能以
大約 **0.1×** 的正常輸入價格*讀取*它。首次佈置的成本約為 **2×** —
只付一次，之後分攤到每一輪。這就是為什麼即使在 200k 上下文之下，
忙碌的工作階段仍然感覺又快又便宜。

問題在於：這個工作區會在**閒置大約一小時**後被悄悄拆除。午餐後
回到一個大型工作階段，你的下一則訊息就得以 2× 費率重建全部 —
恰好在你想要結果的那一刻。此外，只要對話的開頭被改寫，工作區
*不需要*任何閒置時間也會被拆除：`/compact` 會重新整理整個工作區，
因此它總是觸發一次完整重建。

Claude Code 完全不會顯示這些資訊。warmline 讓它變得可見 — 並協助
防止其中可避免的部分。

## 快速上手

```sh
curl -fsSL https://raw.githubusercontent.com/Miguel-Barroso/claude-warmline/main/install.sh | bash

warmline keep-warm on        # optional: prevent avoidable cold starts
warmline keep-warm status    # is it on?
```

然後正常使用 Claude Code — 狀態列會即時顯示快取狀態。
想知道一個工作階段（或全部工作階段）實際花了什麼代價時：

```sh
warmline-audit               # this session, turn by turn
warmline-audit --all         # every session, ranked by where the money leaked
```

## warmline 回答什麼

| | 問題 |
|---|---|
| **statusline** | 現在正在發生什麼？（`cache HOT` / `COLD`，即時） |
| **`warmline-audit`** | 這個工作階段裡發生過什麼，逐輪來看？ |
| **`warmline-audit --all`** | 我的用量在哪裡漏錢，綜觀所有工作階段？ |
| **原因歸因** | 快取*為什麼*變冷 — 閒置、`/compact`、還是漂移？ |
| **keep-warm**（可選） | 我能防止可避免的冷啟動嗎？ |

## 安裝

```sh
curl -fsSL https://raw.githubusercontent.com/Miguel-Barroso/claude-warmline/main/install.sh | bash
```

或從複製下來的原始碼安裝：

```sh
git clone https://github.com/Miguel-Barroso/claude-warmline.git
cd claude-warmline
./install.sh
```

各檔案的落點：`statusline.py` → `~/.claude/warmline-statusline.py`，並接進
`~/.claude/settings.json`（會先備份；已存在的自訂狀態列絕不會在沒有
`--force` 的情況下被取代）；`warmline` 與 `warmline-audit` 指令 →
`~/.local/bin/`（可用 `WARMLINE_BIN_DIR` 覆寫）；keep-warm 策略文字 →
`~/.claude/warmline-keep-warm.md`。Claude Code 通常會在數秒內套用狀態列 —
如果沒有，請重啟工作階段。

如果 `~/.local/bin` 不在你的 `PATH` 上，安裝程式會告訴你，並印出要
加入的確切指令（`export PATH="$HOME/.local/bin:$PATH"`）— 它自己
絕不會編輯你的 shell 啟動檔。

| 旗標 | 效果 |
|---|---|
| `--keep-warm` | 安裝時的簡便寫法，等同 [`warmline keep-warm on`](#keep-warm-保溫策略) |
| `--force` | 取代已存在的非 warmline 狀態列 |
| `--uninstall` | 移除安裝程式加入的一切，包括策略區塊 |
| `--help` | 使用說明 |

需要 `python3`（僅用標準函式庫）和 `bash`。要在 `curl` 形式下傳遞旗標：
`curl -fsSL …/install.sh | bash -s -- --keep-warm`。

**安裝程式負責安裝 warmline；`warmline` 指令負責控制它。**任何時候，
一個指令就能回答「warmline 在這台機器上做了什麼？」：

```
$ warmline status
claude-warmline status  (config: /Users/mb/.claude)
  statusline  ON   /Users/mb/.claude/warmline-statusline.py
  keep-warm   OFF  (enable: warmline keep-warm on)
  auditor     ON   /Users/mb/.local/bin/warmline-audit
  ttl         60m (default)
```

## 如何解讀這條狀態列

| 欄位 | 意義 |
|---|---|
| `ctx 43% (168k)` | 上下文視窗使用率，以及對話中的輸入 token 數 |
| `cache HOT` | 前一個請求讀取了提示快取（綠色） |
| `cache HOT (cold in 9m)` | 仍然溫熱，但閒置間隔距離 TTL 已不到 15 分鐘 — 現在行動，否則就得付重建費（黃色） |
| `cache COLD(rebuilt)` | 前一個請求發現前綴已冷並重新快取了它（黃色） |
| `cache COLD(ttl?)` | *推斷*：工作階段安靜的時間已超過 TTL，因此無論（過時的）usage 欄位怎麼說，快取都已過期（紅色） |
| `cache ?` | usage 欄位不可用 |
| `gap 12m` | 此工作階段距離上一次 API 輪次的分鐘數（從 5m 起顯示；閒置重繪不會重設它） |

色彩預設開啟（Claude Code 會在狀態列中渲染 ANSI）；設定
`NO_COLOR` 或 `WARMLINE_NO_COLOR` 可停用。

誠實的限制：Claude Code 交給狀態列的是*前一個*請求的 usage
數字，因此 `HOT`/`COLD(rebuilt)` 會落後一輪，而 `COLD(ttl?)` 是
基於時間的推斷 — 所以帶著 `?`。這條線也是拉取式的：指令碼只在
Claude Code 重繪它時執行，因此當你的機器休眠時，最後渲染出來的那一行
— 通常是屆時已不成立的 `HOT` — 會凍結在螢幕上。warmline
保證的是閒置時鐘能在重繪之間存活：只有真正的 API 輪次會重設
它，因此你回來後的第一次重繪就已顯示 `COLD(ttl?)` — 在你花掉
任何錢之前。間隔是按工作階段各自追蹤的（時間戳記檔案存放在
`~/.claude/warmline-state/`），因此並行的工作階段不會互相重設對方的時鐘。

實際的用途：大 `ctx` 上的 `COLD(ttl?)` 標記了改變路線成本最低的
時刻 — 見[冷著回來](#冷著回來compactclear還是都不用)。

## 稽核過往工作階段

```sh
warmline-audit                      # latest session of the current project
warmline-audit path/to/session.jsonl
warmline-audit --ttl 5 --json       # short-TTL setups, machine-readable
warmline-audit --price 3            # add dollar estimates, given your
                                    # model's base input price per MTok
warmline-audit --all --price 3      # every session on this machine,
                                    # ranked by estimated avoidable premium
```

（安裝於 `~/.local/bin/`；從原始碼目錄則用 `./warmline-audit`。
`warmline audit …` 是同一件事。）

與狀態列不同（後者依其構造必然落後一輪），稽核是權威的：它評比
每一個被記錄下來的 API 請求。一個真實的工作階段：

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

由上而下解讀：

- **每一列就是一個 API 請求。** `gap` 是它之前的閒置時間；`cache
  read`/`cache write` 是它從快取讀取、或重新寫入快取的 token 數。
- 那一列 `/compact` 是有實證原因的 **`COLD(rebuilt)`**：逐字稿中、
  就在它之前有一個結構化的壓縮邊界標記。沒有任何閒置時間 — 光是
  前綴改寫就殺死了快取。緊接其後的 `PARTIAL` 也很典型：壓縮往往
  讓前綴共享的開頭保持溫熱，因此下一輪能讀回部分快取、同時重寫
  其餘部分。
- 那一列 `6h12m` 才是昂貴的：一夜靜默、快取過期，早晨的第一則訊息
  以 2× 費率重寫了 58k token。那段間隔裡*也*發生了一次壓縮，因此
  稽核工具不猜測，而是標為 **`inactivity+compact`** — 兩者都可能
  解釋這次重建。
- **cache health 快取健康條**是跑在熱狀態的輪次比例。其下是判定
  普查，然後是每個冷輪次*為什麼*發生。（工作階段的第一次快取寫入
  會被評為 `session start`，永遠不計入可避免；這個工作階段恰好是
  恢復到仍溫熱的快取上，所以連這一項都沒有。）
- 最後一行 **estimated avoidable premium（估算的可避免溢價）**，是
  *潛在*可避免的冷重快取相較於溫讀取同樣 token 所多花的成本（一次
  冷重快取的計費約 2×；它取代的溫讀取本來只計費約 0.1× — 相差
  1.9×）。是來自記錄的 token 數的估算，永遠不是帳單資料 —
  見[「可避免」的精確定義](#錢從哪裡漏掉--all)。

原因是歸因，不是猜測：`/compact` 與 `auto-compact` 來自逐字稿中的
結構化標記，`model change` 來自記錄到的模型，`inactivity+compact`
標記兩者皆可解釋的模稜兩可情況，其餘一切誠實地標為 `unknown` —
實務上多半是逐字稿無法證明的前綴漂移（被編輯的 CLAUDE.md、改變的
git 狀態、MCP 可用性）。

### 錢從哪裡漏掉？`--all`

`--all` 會稽核 `~/.claude/projects` 下（或你傳入的目錄下）的每一個
工作階段，每個工作階段一行，依**可避免的冷 token** 排名 — 這個詞
在這裡有精確的定義，就寫在輸出下方。以下是這台機器 8 週歷史的
真實輸出：

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

**「可避免」的精確定義。**每個工作階段都必須為它的第一次快取寫入
付費：對話總得先被快取一次，之後才有任何東西能被便宜地讀回。
warmline 永遠不把這一筆算進去。它算作*可避免*的，是在那之後每一個
以冷狀態重新快取的 token — 由 TTL 過期、壓縮或前綴漂移造成的重建，
而不同的時機（一次保溫 ping、更早的一次主動 `/compact`、一個穩定的
前綴）*或許*能防止它們。因此這個數字是曝險的估算，不是實際浪費掉
的錢：其中一部分在實務上無法防止（筆電休眠期間的 TTL 過期也會被
算作「可避免」，儘管當時不可能有任何 ping 觸發），而且全部都是從
你逐字稿裡記錄的 token 數計算出來的 — warmline 從未看到、也無法
看到 Anthropic 實際向你的帳戶收了多少錢。

怎麼讀：排在前面且 `ttl` 計數很大的工作階段是保溫候選 — 那是走開時
流失的錢。大量的 `rebuilt`/`unknown` 計數表示前綴變動：有東西在輪次
之間改寫了對話前綴。大量的 `auto-compact` 表示工作階段經常撞上上下文
上限，這種情況下更早、更主動地壓縮（見下文）比較便宜。最後一行的
拆分是集中度：漏錢是少數幾場災難，還是薄薄地攤在各處？在這台機器
上是後者 — 前五名工作階段只佔溢價的三分之一，這與誠實的結論相符：
無聲的前綴漂移（`unknown 89`）重建的快取比壓縮（43）還多。錢漏掉
的地方很少是你以為的那裡。

管道或 CI 輸出保持純文字（長條圖與色彩以 TTY 為條件），而 `--json`
保持不變、可供機器讀取。

## Keep Warm 保溫策略

以上的一切都在*觀測*。Keep Warm 是可選的另一半，負責*預防*：它讓
快取在你打算回來的長時間等待中不至於過期。

```sh
warmline keep-warm on        # turn it on (once)
warmline keep-warm status    # is it on?
warmline keep-warm off       # turn it off
```

就這樣。它是全域的（`~/.claude/CLAUDE.md` 裡的一個區塊），適用於
每一個專案，並且在工作階段與安裝程式更新之間持續存在 — 設定一次
就能忘記。（`./install.sh --keep-warm` 會在安裝時執行同一個啟用
動作；`--uninstall` 會連同其他一切一併移除它。）

```
$ warmline keep-warm status
keep-warm  ON
  scope    global -- applies to every project  (block in /Users/mb/.claude/CLAUDE.md)
  policy   intact
```

`status` 永遠不信任任何狀態檔 — 它每次都讀你實際的 CLAUDE.md。
手動刪掉區塊，它會回報 OFF；留下半個區塊，它會回報 INCONSISTENT
並附上修法，而不是一個虛假的 ON。給指令稿用的話，結束代碼就是
答案：`0` 開啟、`1` 關閉、`2` 不一致。

**它是什麼：**一小段以標記分隔的指示區塊
（[`keep-warm.md`](keep-warm.md)），你的代理會在活躍的工作階段中
遵循它。當代理啟動預期超過約 45 分鐘的背景工作、且上下文可觀時，
它會排程一次約 50 分鐘後的喚醒；醒來時若工作仍在進行就重新排程，
否則正常繼續 — 結果就落在熱快取上。每次 ping 花費約 0.1× 上下文的
快取讀取額度，相較於冷重寫的約 2×，因此*只要你會回來*，它在長達約
10–12 小時的閒置期間都能回本。

**它不是什麼：**

- **不是常駐程式。** 沒有背景行程、沒有 cron、在執行中的 Claude Code
  工作階段之外不發出任何請求。Claude Code 沒在跑，就什麼都沒在跑。
- **不是永遠開著。** 當本機背景任務已在進行時它會刻意*跳過*（它們的
  通知免費保住快取溫度 — 下文有量測），也會跳過小上下文，因為變冷
  很便宜。
- **不會比等待活得更久。** 工作一恢復，喚醒就被刪除；而單次等待在
  約 12 次重新排程（約 10 小時）後就會放棄 — 超過那個點，ping 的
  成本已高於它所防止的那次重建。

**它無法運作的情況：**喚醒無法在休眠的主機上觸發（macOS 上
`caffeinate -is` 能讓計畫中的等待保持清醒）。某些 Claude Code 版本上
`ScheduleWakeup` 可能不存在或受限 — 代理會退回使用週期性的排程提示
（`/loop 50m <ping>`），或者該區塊就只是惰性的。而且它是指示、不是
程式碼：代理可能沒有遵循。稽核就是你驗證它是否真的有效的方法。

**這符合 Anthropic 的條款嗎？** 我們實際研究過，而不是假設。
keep-warm 依賴的機制是有文件記載的產品行為：Anthropic 的
[提示快取文件](https://platform.claude.com/docs/en/build-with-claude/prompt-caching)
寫明快取「每次被使用時都會免費刷新」（"is refreshed at no additional
cost each time the cached content is used"），而且對 API 使用情境，
官方明確建議定期發送預熱請求。一次 keep-warm ping 是活躍工作階段內
的一個普通計費請求：它消耗你自己的額度（通常*少於*它所取代的冷
重建），也不繞過任何東西。真正要緊的界線在另一邊 — Anthropic 的
每週限制是為了遏止讓 Claude Code 全天候 24/7 連續運轉的帳號。這正是
這套策略在設計上就有邊界的原因：它只在你打算回來的真實等待中 ping、
頻率最多約每 50 分鐘一次、當溫度已經免費維持時跳過、工作一恢復就
停止、約 10 小時後放棄，而且永遠不是常駐程式。請不要放寬這些邊界。
仍有一個誠實的未知：消費者 Claude Code 工作階段內的排程 ping 是否
算在訂閱方案所假設的「一般個人使用」（"ordinary, individual usage"）
之內，在我們能找到的任何地方都沒有被回答 — Anthropic 對這個特定
用法的確切立場是未知的。這一切不代表 Anthropic 為 keep-warm 背書 —
它代表我們沒有找到它違反的規則，並且把它打造成遠離 Anthropic 曾
採取行動的那類行為。

## 冷著回來：`/compact`、`/clear`，還是都不用？

大上下文上的 `COLD(ttl?)` 是一個岔路口。快取已經沒了；接下來不管
你做什麼，那段上下文都會以昂貴的無快取費率再被處理一次。
唯一的問題是，這一次無可避免的處理能為你換來什麼：

- **你還需要對話歷史 → `/compact`。** 壓縮必須把整段對話
  讀過一次才能摘要。在熱快取上這次讀取本來很便宜
  — 但它同時會摧毀你已付 2× 建立的快取，這就是
  為什麼在 `HOT` 時壓縮是時機最糟的一步（除非上下文視窗
  用完、別無選擇）。在冷快取上，那次昂貴的處理反正在你的
  下一則訊息就會發生 — 壓縮只是把它導向產出一份小摘要，
  從此之後你快取並攜帶的只有數千個
  token 而不是 100k+。`/compact` 恰好在快取已經死掉時效益最大。
- **你的狀態已寫在對話之外 → `/clear`。** 如果繼續
  所需的內容存在於記憶檔案、計畫文件、或程式碼與 git
  歷史本身，`/clear` 連摘要那一次處理都省了 — 再也沒有任何東西
  需要付費重讀舊上下文。新工作階段的前綴只有系統提示、你的
  CLAUDE.md，以及記憶索引；檔案只在變得相關時才會被重讀，
  這幾乎總是遠低於對一段 100k+ 對話做一次摘要處理的成本。
- **小上下文 → 什麼都不做。** 在 20k token 時變冷，重建很便宜。
  這裡的一切都是為 100k+ 的情況而存在的。

## 我們實際量測到的（不是建模出來的）

以上每一個主張都可以對照真實逐字稿驗證 — Claude Code 會為每一個
API 輪次記錄 `cache_read_input_tokens` 和
`cache_creation_input_tokens`，而 `warmline-audit` 會評比它們。
以下來自一個真實的 13 小時協調工作階段（2026-08-18，約 300k 上下文，
帶背景 CI 監看器的合併佇列看護）：

- **260 個 API 輪次：255 HOT、1 COLD(rebuilt)、1 COLD(ttl)** — 從快取讀取了
  45.9M token；只有 99k token 曾在冷狀態下重新快取。
- 每約 9 分鐘抵達一次的背景任務通知，以**每次喚醒僅約 400 token 的快取寫入**
  讓快取連續四小時保持溫熱（同期讀取量從
  150k 成長到 317k）。**只要有背景工作在進行，它的通知就能免費保住快取的
  溫度** — 不需要任何策略。
- 那一次 `COLD(ttl)` 出現在 6 小時的夜間靜默之後 — 機器在休眠，
  所以什麼都不可能觸發。**沒有任何排程喚醒能撐過闔上的螢幕**（在 macOS 上，
  `caffeinate` 是計畫性長時間等待的因應之道）。
- 那一次 `COLD(rebuilt)` 緊跟在 `/compact` 之後：活動後數分鐘內
  就發生了完整的 58k token 重新快取。前綴失效與 TTL 過期是不同的故障模式，
  這正是狀態列將兩者區分開來的原因。
- 無頭探測確認了 TTL 級距：Claude Code 以
  `ephemeral_1h`（1 小時 TTL）寫入快取，而恢復的工作階段會讀回其完整前綴
  （參考探測中讀取 33,614 token、寫入 56 token）。
- TTL 邊界本身則是在一次潔淨室雙臂實驗中量測的（隔離的無頭
  工作階段、無 MCP 伺服器、凍結的環境）：完全靜默 **50 分鐘**後，
  一次探測從快取讀取了完整的 71,312 token 前綴、只寫入 56
  token；**70 分鐘**後，一個相同的工作階段發現快取已消失，
  重寫了全部 45,033 token。50 分鐘時仍溫、70 分鐘時已冷 — 1 小時
  TTL 是真實的，而保溫 ping 間隔（約 50 分鐘）安全地落在其內。
- 冷臂也順帶示範了 ping *為什麼*有效：**讀取會刷新 TTL**。
  它的探測仍然發現共享的系統區塊是溫的，因為另一臂在
  20 分鐘前讀過那個區塊。保溫 ping 正是這樣的刷新，
  套用到你的整個前綴上。
- 綜觀這台機器的完整歷史（8 週共 145 個工作階段），
  `warmline-audit --all` 以 Sonnet 基準價格估算的可避免溢價總計為
  **~$66** — 其中把 43 次快取重建歸因於壓縮，但有 **89 次歸因於
  原因不明的前綴漂移**。錢漏掉的地方很少是你以為的那裡。
- 同一實驗較早、刻意不乾淨的一次執行揭露了更微妙的
  故障模式：無頭 `--resume` 會重新產生
  整個系統提示，因此輪次之間的 git 狀態漂移、MCP 伺服器可用性變化、或
  被編輯過的 CLAUDE.md 都會讓前綴悄悄分歧 — 而分歧點之後的
  一切都以全價重新快取。**前綴穩定性與 TTL 同等重要**：
  對於前綴在輪次之間不斷變動的工作階段，任何保溫 ping 都無能為力。

## 設定

| 環境變數 | 預設值 | 意義 |
|---|---|---|
| `WARMLINE_TTL_MIN` | `60` | 提示快取的 TTL（分鐘）（短 TTL 環境請設 `5`） |
| `WARMLINE_STATE_DIR` | `~/.claude/warmline-state` | 時間戳記／狀態目錄 |
| `WARMLINE_BIN_DIR` | `~/.local/bin` | 安裝程式放置 `warmline` 與 `warmline-audit` 指令的位置 |
| `WARMLINE_NO_COLOR` | 未設定 | 若設定（或設定了 `NO_COLOR`），輸出純文字、不含 ANSI 色彩 |
| `WARMLINE_FORCE_COLOR` | 未設定 | 若設定，即使在管道中也輸出彩色的稽核報告 |
| `WARMLINE_DEBUG` | 未設定 | 若設定，保留最後一筆原始狀態列酬載以供檢視 |

請在 Claude Code 啟動時所處的環境中設定這些變數，或設定在
`~/.claude/settings.json` 的 `env` 區塊裡。狀態列與
`warmline-audit` 都會採用 `WARMLINE_TTL_MIN`。

## 相容性與更新

已針對 Claude Code **2.1.233**（撰寫當時的最新版）驗證。狀態列的
JSON 欄位已對照真實的 harness 酬載檢查，而
`warmline-audit` 能解析這台機器上出現過的所有逐字稿格式 —
Claude Code 版本 **2.1.181 到 2.1.233**、145 個工作階段、零格式錯誤
項目。已處理一個已知的格式怪癖：某些版本約
28% 的 assistant 項目缺少 `requestId`，因此稽核工具改以 `message.id` 對 API 請求去重。

**更新：**安裝程式就是更新程式。重新執行同一行 `curl | bash`
（或在拉取後的原始碼中執行 `./install.sh`）— 它會辨識出自己的
狀態列，並就地取代狀態列、`warmline` 指令與稽核工具、無需
`--force`；每次執行都會備份你的 `settings.json`，而你的 keep-warm
開／關選擇會保持原狀。
[CHANGELOG.md](CHANGELOG.md) 記錄各標記版本之間的變更。

**Windows：**狀態列與稽核工具都是純標準函式庫的 Python，
與作業系統無關；只有安裝程式和測試套件是 bash。手動
安裝：

1. 把 `statusline.py` 複製到 `%USERPROFILE%\.claude\warmline-statusline.py`
   （也可以把 `warmline-audit` 複製到任何方便的位置）
2. 在 `%USERPROFILE%\.claude\settings.json` 中設定
   `"statusLine": {"type": "command", "command": "python C:\\Users\\you\\.claude\\warmline-statusline.py"}`
3. 以 `python warmline-audit [args]` 執行稽核工具

`warmline` 指令同樣是 bash，因此在 Windows 上請手動切換 keep-warm —
在 `%USERPROFILE%\.claude\CLAUDE.md` 中加入或移除以標記分隔的區塊
（內容就是 [`keep-warm.md`](keep-warm.md)）— 或改用 WSL / Git Bash。
ANSI 色彩在 Windows Terminal 中渲染正常。一份經過測試的 `install.ps1` 會是
很受歡迎的貢獻 — 秉持本專案的理念，我們不出貨
自己無法測試的東西。

## 測試

```sh
./test.sh
```

以具代表性的狀態列酬載（熱、冷重建、TTL 過期、稀疏、
垃圾資料、並行工作階段隔離、閒置重繪不重設時鐘、
新輪次覆蓋 TTL 推斷、過期倒數、ANSI 色彩）
重播測試該指令碼；以合成逐字稿測試 `warmline-audit`，包括
`--price` 估算、每一種冷原因歸因，以及 TTY 與管道輸出格式；
以合成的多專案語料測試 `--all`；並測試 `warmline` CLI 的 keep-warm
狀態轉換（on→on、off→off、格式損壞的區塊被如實回報而不是一個
虛假的 ON），同時驗證無關的 CLAUDE.md 內容能在每一個操作後倖存，
以及乾淨安裝確實會讓 `warmline` 指令就位。同一套測試在每次推送時
於 CI 中執行。

## 授權條款

[MIT](LICENSE)

## 請我喝杯咖啡 ☕

BTC: `bc1qjsvtd3dd44llyu4rwz2ucl4kp9wd9kvpsj6tk5`
