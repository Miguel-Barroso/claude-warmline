# claude-warmline

[English](README.md) | [日本語](README.ja.md) | **繁體中文** | [简体中文](README.zh-CN.md)

[![tests](https://github.com/Miguel-Barroso/claude-warmline/actions/workflows/test.yml/badge.svg)](https://github.com/Miguel-Barroso/claude-warmline/actions/workflows/test.yml)
[![version](https://img.shields.io/github/v/tag/Miguel-Barroso/claude-warmline?label=version)](https://github.com/Miguel-Barroso/claude-warmline/tags)
[![license](https://img.shields.io/github/license/Miguel-Barroso/claude-warmline)](LICENSE)

**提前得知你的 Claude Code 工作階段什麼時候會醒得又慢又貴 — 並預先防範。**

Claude Code 每次傳送訊息時都會重新送出整段對話。伺服器端的
*提示快取*讓這件事便宜約 10 倍 — 直到它在安靜約一小時後悄悄過期，
而你的下一輪就得付出雙倍價格重建它。claude-warmline
是針對這個問題的三個小工具，除了 `python3` 和 `bash` 之外沒有任何相依套件：

- **一條狀態列**：即時顯示快取狀態（`HOT`/`COLD`），與模型、上下文使用量、閒置時間並列
- **一套 keep-warm 保溫策略**：讓代理在漫長等待中以低成本 ping 工作階段，使結果落在熱快取上
- **一個稽核工具**：逐輪評比任何過去的工作階段 — 哪些保持溫熱、哪些變冷、*為什麼*、花了多少錢 — 並可用 `--all` 依金錢流失處為你機器上的每一個工作階段排名

![warmline 狀態列的三種狀態：綠色的 cache HOT、黃色的 cache COLD(rebuilt)、紅色的 cache COLD(ttl?)](docs/statusline.svg)

## 第一次接觸？60 秒背景知識

Claude 在請求與請求之間不會記得任何事。每次你傳送訊息，
Claude Code 都會重新送出至今的*整段*對話 — 系統提示、工具、每一個
被讀取過的檔案、每一則回覆。在長時間的工作階段裡，每一輪的輸入輕易就超過
100k token，而你每次都得為全部內容付費。

**提示快取**正是讓這一切負擔得起的關鍵：供應商把你的
對話前綴快取在伺服器端，因此下一個請求以大約
**0.1×** 的正常輸入價格*讀取*它，而不是重新處理。首次寫入快取的
成本約為 **2×** — 這筆溢價只付一次，之後分攤到每一輪
後續對話。這就是為什麼即使在 200k 上下文之下，忙碌的工作階段仍然感覺又快又便宜。

問題在於：快取會在 **TTL 之後過期 — 大約閒置 1 小時**。午餐後
回到一個大型工作階段，下一個請求會悄悄地在沒有快取的情況下重新處理所有內容，
並再次支付 2× 的重寫溢價 — 恰好在你想要結果的那一刻。此外，只要對話前綴
改變，快取*不需要*任何閒置時間也會死掉：`/compact` 會改寫整個上下文，
因此它總是觸發一次完整的重新快取。

Claude Code 完全不會顯示這些資訊。warmline 讓它變得可見。

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
它，因此你回來後的第一次重繪就已顯示 `COLD(ttl?)` — 在
你花掉任何錢之前 — 並且會一直保持這樣，直到有請求真正落地。
間隔是按工作階段各自追蹤的（時間戳記檔案存放在 `~/.claude/warmline-state/`），
因此同一台機器上並行的 Claude Code 工作階段不會互相重設對方的閒置時鐘。

實際的用途：大 `ctx` 上的 `COLD(ttl?)` 標記了改變路線成本最低的
時刻 — 至於該往哪個方向跳，就是下一節的主題。

## 冷著回來：`/compact`、`/clear`，還是都不用？

大上下文上的 `COLD(ttl?)` 是一個岔路口。快取已經沒了；接下來不管
你做什麼，那段上下文都會以昂貴的無快取費率再被處理一次。
唯一的問題是，這一次無可避免的昂貴處理能為你換來什麼：

- **你還需要對話歷史 → `/compact`。** 壓縮必須把整段對話
  讀過一次才能摘要。在熱快取上這次讀取本來很便宜
  — 但它同時會摧毀你已付 2× 建立的快取，這就是
  為什麼在 `HOT` 時壓縮是時機最糟的一步（除非上下文視窗
  用完、別無選擇）。在冷快取上，那次昂貴的處理反正在你的
  下一則訊息就會發生 — 壓縮只是把它導向產出一份小摘要，
  從此之後你快取並攜帶的只有數千個
  token 而不是 100k+。這就是為什麼 `/compact` 恰好在
  快取已經死掉時效益最大。
- **你的狀態已寫在對話之外 → `/clear`。** 如果繼續
  所需的內容存在於記憶檔案、計畫文件、或程式碼與 git
  歷史本身，`/clear` 連摘要那一次處理都省了 — 再也沒有任何東西
  需要付費重讀舊上下文。而且新的工作階段並*不會*把所有東西
  吸回來：它的前綴只有系統提示、你的 CLAUDE.md，以及
  單行的記憶索引 — 個別的記憶檔案和專案檔案只在
  變得相關時才會被讀取。這種有針對性的重讀會花費新的輸入
  token，但幾乎總是遠低於對一段 100k+ 對話做一次
  摘要處理的成本。
- **小上下文 → 什麼都不做。** 在 20k token 時變冷，重建很便宜。
  量表和保溫策略都是為 100k+ 的情況而存在的。

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

安裝程式會把 `statusline.py` 複製到 `~/.claude/warmline-statusline.py`，並把它
接進 `~/.claude/settings.json`（會先備份你原本的 `settings.json`；
已存在的自訂狀態列絕不會在沒有 `--force` 的情況下被取代）。Claude Code 通常
會在數秒內套用 — 如果沒有，請重啟工作階段。

| 旗標 | 效果 |
|---|---|
| `--keep-warm` | 同時把保溫策略區塊附加到 `~/.claude/CLAUDE.md` |
| `--force` | 取代已存在的非 warmline 狀態列 |
| `--uninstall` | 移除指令碼、settings 項目、狀態檔案與策略區塊 |

需要 `python3`（僅用標準函式庫）和 `bash`。

## 我們實際量測到的（不是建模出來的）

以上所有主張都可以對照真實逐字稿驗證 — Claude Code 會在
工作階段的 `.jsonl` 檔案裡為每一個 API 輪次記錄
`cache_read_input_tokens` 和 `cache_creation_input_tokens`，而 [`warmline-audit`](#稽核過往工作階段) 會評比它們。
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
  重寫了其內容的全部 45,033 token。50 分鐘時仍溫、70 分鐘時已冷 — 1 小時
  TTL 是真實的，而保溫 ping 間隔（約 50 分鐘）安全地落在其內。
- 冷臂也順帶示範了 ping *為什麼*有效：**讀取會刷新 TTL**。
  它的探測仍然發現共享的系統區塊是溫的，因為另一臂在
  20 分鐘前讀過那個區塊。保溫 ping 正是這樣的刷新，
  套用到你的整個前綴上。
- 綜觀這台機器的完整歷史（8 週共 149 個工作階段），
  [`warmline-audit --all`](#錢從哪裡漏掉--all) 以 Sonnet 基準價格
  估算的可避免溢價總計為 **~$64** — 其中把
  43 次快取重建歸因於壓縮，但有 **87 次歸因於原因不明的
  前綴漂移**。錢漏掉的地方很少是你以為的那裡。
- 同一實驗較早、刻意不乾淨的一次執行揭露了更微妙的
  故障模式：無頭 `--resume` 會重新產生
  整個系統提示，因此輪次之間的 git 狀態漂移、MCP 伺服器可用性變化、或
  被編輯過的 CLAUDE.md 都會讓前綴悄悄分歧 — 而分歧點之後的
  一切都以全價重新快取。**前綴穩定性與 TTL 同等重要**：
  對於前綴在輪次之間不斷變動的工作階段，任何保溫 ping 都無能為力。

## keep-warm 保溫策略

`--keep-warm` 會在你的全域 `~/.claude/CLAUDE.md` 附加一小段以標記分隔的區塊
（見 [`keep-warm.md`](keep-warm.md)），指示代理：當它啟動預期
超過約 45 分鐘的背景工作、且上下文可觀時，排程一次
約 50 分鐘後的喚醒；醒來時若工作仍在進行就重新排程，否則繼續 —
且絕不讓喚醒比等待活得更久。如此一來，結果永遠落在熱快取上。

它什麼時候真正重要 — 什麼時候不重要：

- **背景任務執行期間是多餘的。** 它們的完成通知
  已經會在 TTL 之內喚醒工作階段（上文已量測）。策略會告訴
  代理在這種情況下略過排程。
- **當工作階段真正安靜下來時很有價值** — 等待遠端 CI 而沒有
  本機監看器，或人暫時離開、留著 100k+ 的溫熱上下文並打算
  回來。每次 ping 花費約 0.1× 上下文的快取讀取額度，相較於
  冷重寫的約 2×，因此*只要你會回來*，保溫在長達約
  10–12 小時的閒置期間都能回本。策略刻意跳過小上下文，
  因為變冷很便宜。
- **會被主機休眠擊敗。** 喚醒無法在休眠的機器上觸發。macOS 上
  計畫性的長時間等待：`caffeinate -is`（或接上電源並保持螢幕開啟）。

工具可用性因 Claude Code 版本而異：`ScheduleWakeup` 可能不存在，或
存在但受執行期限制（在動態 `/loop` 工作階段之外會被拒絕）。在這類版本上，
該區塊會是惰性的，或者代理會退回使用排程的週期性提示 —
`/loop 50m <ping>` 透過 cron 達成相同的喚醒節奏。

## 稽核過往工作階段

```sh
./warmline-audit                      # latest session of the current project
./warmline-audit path/to/session.jsonl
./warmline-audit --ttl 5 --json       # short-TTL setups, machine-readable
./warmline-audit --price 3            # add a dollar estimate, given your
                                      # model's base input price per MTok
./warmline-audit --all --price 3      # every session on this machine,
                                      # ranked by estimated avoidable premium
```

每個 API 輪次印出一行 — 時間戳記、閒置間隔、快取讀／寫 token 數、判定 —
外加一段冷狀態下重新快取總量的摘要。冷的（以及大量重寫的）輪次
在逐字稿確實能支持時會標上**原因**：

```
time                gap   cache read   cache write  verdict
08-18 10:02:45    6h12m            0        58,427  COLD(ttl)
08-19 10:37:40    7h56m            0        31,841  COLD(ttl)  <- inactivity+compact
08-19 10:40:13       2m            0        52,386  COLD(rebuilt)  <- unknown
08-18 10:13:56      10m       62,567           710  HOT

260 API turns; HOT 255  PARTIAL 3  COLD(rebuilt) 1  COLD(ttl) 1
causes: inactivity 1  session start 1
tokens re-cached while cold: 99,188   read from cache: 45,926,103
```

原因是歸因，不是猜測。`/compact` 與 `auto-compact` 表示
逐字稿中、此輪與上一輪之間存在一個結構化的壓縮邊界標記
（壓縮通常會讓共享的前綴開頭保持溫熱，所以它
會顯示為有歸因的 `PARTIAL`，而不是完全的冷重建）。
`model change` 表示記錄到的模型與上一輪的不同。
`session start` 是每個工作階段都必須支付的第一次快取寫入。
`inactivity+compact` 標記模稜兩可的情況：長間隔和
壓縮都可能解釋這次重建 — 兩者都不作主張。其餘一切
誠實地標為 `unknown`：實務上多半是逐字稿無法證明的前綴漂移
（被編輯的 CLAUDE.md、改變的 git 狀態、MCP 可用性）。

與狀態列不同（後者依其構造必然落後一輪），稽核是
權威的：它讀取每一個請求記錄下來的 usage。用它來驗證
保溫策略是否真的讓你保持溫熱，或查明一次 `/compact` 或一夜的
間隔究竟花了多少錢。

### 錢從哪裡漏掉？`--all`

`--all` 會稽核 `~/.claude/projects` 下（或你傳入的目錄下）的每一個工作階段，
每個工作階段印出一行，依**可避免的冷 token** 排名 — 即冷狀態下
重新快取的 token，扣除每個工作階段無可避免的首次寫入。以下是這台機器
8 週歷史的真實輸出：

```
149 sessions under /Users/mb/.claude/projects  (13 more without API turns; ttl 60m)

start        project            turns    hot  part  rebuilt   ttl  avoidable cold    premium
08-07 14:30  MimirBlue            201    189     6        4     2       1,294,770      $7.38
08-08 10:57  MimirBlue             66     58     1        4     3         814,630      $4.64
08-18 17:41  claude-warmline      111    104     1        3     3         401,451      $2.29
...
TOTAL                          11,058 10,548   329      147    34      11,288,198     $64.34

causes: inactivity 27  inactivity+compact 7  /compact 7  auto-compact 36  model change 3  unknown 87  session start 53
```

那個美元數字是什麼 — 又不是什麼：加上 `--price <base $/MTok>` 後，premium
欄是**估算的可避免溢價** — 可避免的冷 token × 1.9 ×
你模型的基準輸入價格（一次冷重快取的計費約 2×；它所取代的
溫讀取本來只計費約 0.1×）。它來自你的逐字稿中記錄的 token 數量，
而不是帳單資料，並且忽略工作階段內各模型之間的價格差異
以及子代理逐字稿（獨立檔案、獨立前綴，刻意排除）。
把它當作排名訊號，而不是發票。

怎麼讀：排在前面且 `ttl` 計數很大的工作階段是保溫
候選 — 那是走開時流失的錢。大量的 `rebuilt`/`unknown` 計數表示
前綴變動：有東西在輪次之間編輯了對話前綴。大量的
`auto-compact` 表示工作階段經常撞上上下文上限，這種情況下
更早、更主動地壓縮（見上文）比較便宜。在這台機器上，
誠實的結論是：無聲的前綴漂移（`unknown 87`）重建的快取
比壓縮（43）還多 — 錢漏掉的地方很少是你以為的那裡。

## 設定

| 環境變數 | 預設值 | 意義 |
|---|---|---|
| `WARMLINE_TTL_MIN` | `60` | 提示快取的 TTL（分鐘）（短 TTL 環境請設 `5`） |
| `WARMLINE_STATE_DIR` | `~/.claude/warmline-state` | 時間戳記／狀態目錄 |
| `WARMLINE_NO_COLOR` | 未設定 | 若設定（或設定了 `NO_COLOR`），輸出純文字、不含 ANSI 色彩 |
| `WARMLINE_DEBUG` | 未設定 | 若設定，保留最後一筆原始狀態列酬載以供檢視 |

請在 Claude Code 啟動時所處的環境中設定這些變數，或設定在
`~/.claude/settings.json` 的 `env` 區塊裡。狀態列與
`warmline-audit` 都會採用 `WARMLINE_TTL_MIN`。

## 相容性與更新

已針對 Claude Code **2.1.233**（撰寫當時的最新版）驗證。狀態列的
JSON 欄位已對照真實的 harness 酬載檢查，而
`warmline-audit` 能解析這台機器上出現過的所有逐字稿格式 —
Claude Code 版本 **2.1.181 到 2.1.233**、149 個工作階段、零格式錯誤
項目。已處理一個已知的格式怪癖：某些版本約
28% 的 assistant 項目缺少 `requestId`，因此稽核工具改以 `message.id` 對 API 請求去重。

**更新：**安裝程式就是更新程式。重新執行同一行 `curl | bash`
（或在拉取後的原始碼中執行 `./install.sh`）— 它會辨識出自己的
狀態列並就地取代、無需 `--force`，而且每次執行都會備份你的
`settings.json`。[CHANGELOG.md](CHANGELOG.md) 記錄各標記版本之間的
變更。

**Windows：**狀態列與稽核工具都是純標準函式庫的 Python，
與作業系統無關；只有安裝程式和測試套件是 bash。手動
安裝：

1. 把 `statusline.py` 複製到 `%USERPROFILE%\.claude\warmline-statusline.py`
2. 在 `%USERPROFILE%\.claude\settings.json` 中設定
   `"statusLine": {"type": "command", "command": "python C:\\Users\\you\\.claude\\warmline-statusline.py"}`
3. 以 `python warmline-audit [args]` 執行稽核工具

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
`--price` 估算與每一種冷原因歸因（含模稜兩可的
那種）；並以合成的多專案語料測試 `--all`（探索、子代理
排除、排名、總計、JSON）。同一套測試在每次推送時於 CI 中執行。

## 授權條款

[MIT](LICENSE)

## 請我喝杯咖啡 ☕

BTC: `bc1qjsvtd3dd44llyu4rwz2ucl4kp9wd9kvpsj6tk5`
