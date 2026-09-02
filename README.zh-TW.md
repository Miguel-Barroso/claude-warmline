# claude-warmline

[English](README.md) | [日本語](README.ja.md) | **繁體中文** | [简体中文](README.zh-CN.md)

[![tests](https://github.com/Miguel-Barroso/claude-warmline/actions/workflows/test.yml/badge.svg)](https://github.com/Miguel-Barroso/claude-warmline/actions/workflows/test.yml)
[![version](https://img.shields.io/github/v/tag/Miguel-Barroso/claude-warmline?label=version)](https://github.com/Miguel-Barroso/claude-warmline/tags)
[![license](https://img.shields.io/github/license/Miguel-Barroso/claude-warmline)](LICENSE)

**warmline 讓 Claude Code 的提示快取狀態變得看得見。**

## Claude Code 會悄悄冷掉

一個正在工作的工作階段帶著幾萬到幾十萬 token——系統提示、工具、它讀過的每個檔案、
每一則回覆——而 Claude Code 每一輪都把這些全部重新送出。只要提示快取還在，那段脈絡
就以大約正常輸入價格的 **0.1 倍**被*讀*回來；一旦冷掉，同樣的脈絡就得以約 **2 倍**
的價格重新處理一次。它會在大約一小時無操作後冷掉，也會在對話開頭被改寫的瞬間立刻
冷掉（`/compact` 與自動壓縮都會這樣做）。午餐後回到一個大工作階段，你的下一則訊息
就要重付全部的重建成本——偏偏在你最想要結果的時刻，而工作階段本身不會告訴你。

**warmline 把快取狀態直接放到你的狀態列上，並給你工具去查看它在歷史上的表現。**

```text
Opus 5 | claude-warmline | ctx 64% (127k) | cache HOT (127k, cold ~11:58) | 5h 78%
```

不靠猜測，也不靠計時推論。從 v2.1.251 起，Claude Code 會把它自己的 `prompt_cache`
物件交給狀態列——前綴是否是熱的、走的是哪個 TTL、在哪一秒過期——warmline 只是把這個
物件裡寫著的內容顯示出來。

至於這一輪之前的一切：

```text
warmline audit
```

會依據 Claude Code 記錄的用量，為一個工作階段的每個 API 輪次評分；`--all` 則把本機
所有工作階段排序呈現。

![狀態列的五種狀態：帶過期時刻的綠色 cache HOT、接近過期時的黃色 cache HOT、紅色 cache COLD，以及 Claude Code 沒有快取資料時暗色的 cache off 與 cache ?](docs/statusline.svg)

## 安裝

```sh
curl -fsSL https://raw.githubusercontent.com/Miguel-Barroso/claude-warmline/main/install.sh | bash
```

在 macOS 上用 Homebrew 也可以：

```sh
brew install Miguel-Barroso/warmline/warmline
```

接著：

| 指令 | 作用 |
|---|---|
| `warmline status` | 目前安裝並啟用了什麼 |
| `warmline audit` | 本專案最近一個工作階段，逐輪查看 |
| `warmline audit --all` | 本機所有工作階段，排序呈現 |
| `warmline watch` | 所有工作階段的溫度，即時顯示，直到 ctrl-c |

只需要 `python3` 與 `bash`，沒有別的依賴。沒有 `curl` 也行：`wget -qO- <同一個 URL> | bash`
效果一樣，安裝器自己下載檔案時也會用它找得到的那一個。無論走哪條路都只有一條指令：
`brew install` 連狀態列一起接好，`brew upgrade` 會換到新版本，`brew uninstall` 會拆掉。

[安裝細節、參數、鎖定發行版、套件管理器、Windows →](docs/INSTALL.md)（英文）

## 為什麼是 warmline

大多數 Claude Code 狀態列回答的是這類問題：

- 我在用哪個模型？
- 脈絡還剩多少？
- 這個工作階段花了多少錢？
- 我在哪個分支上？

這些都有用。warmline 回答的是另一個：

> **提示快取現在真的是熱的嗎？**

以及一個任何即時指示器都答不了的問題：

> **它是什麼時候冷的、多久發生一次、值不值得在意？**

狀態列告訴你工作階段裡正在發生什麼。**warmline 告訴你脈絡是否還在被重複使用。**

這裡的一切都是為 10 萬 token 以上的情況而存在。2 萬 token 冷掉了重建也很便宜。

## 從看得見到管得住

**觀測（Observe）**——快取此刻的狀態，來自 Claude Code 自己的資料，就在狀態列上。

**解釋（Explain）**——`HOT`、`COLD`、`off` 與過期時刻各自代表什麼，其中哪些是你
能採取行動的。

**度量（Measure）**——`warmline audit`：歷史上的冷事件、記錄能證明成因時的原因，
以及它們大約值多少錢的估算。

**緩解（Mitigate）**——`warmline keep-warm`，只在你確認自己確實需要時。

這是一個遞進，而不是功能清單。它帶你從*「我的快取冷掉了嗎？」*走到*「這多久發生
一次？」*，再到*「它貴到值得我在意嗎？」*，最後到*「我想為此做點什麼嗎？」*——而
最後這一問，答案常常是不用。

前三項是唯讀的觀測，也是本專案的重點。第四項需要主動開啟，預設關閉，而且刻意設有
邊界——見下方「選用：保溫」一節。

## 觀測：狀態列

```
Opus 5 | claude-warmline | ctx 64% (127k) | cache HOT (127k, cold ~11:58) | 5h 78%
```

| 欄位 | 意義 |
|---|---|
| `ctx 64% (127k)` | 脈絡視窗使用率——距離自動壓縮真正觸發的門檻（`視窗 - 33000` token）不足 10k 時轉黃 |
| `cache HOT (127k, cold ~11:58)` | 快取的前綴是熱的，若冷掉需要重寫 127k token，並將在所示時間離開它的 TTL；過期前 15 分鐘內文字不變，只轉黃 |
| `cache HOT 5m` | 同上，但走的是 5 分鐘 TTL——用量額度、API key、雲端供應商。1 小時是常態，因此不標註 |
| `cache COLD` | 前綴已在 TTL 之外；下一輪會把它重新快取 |
| `cache off` | 提示快取被關閉，或這個供應商／閘道從不回報快取 token。這裡等再久都不會變熱 |
| `cache ?` | 沒有快取資料——v2.1.251 之前的 Claude Code，或本工作階段第一次 API 回應之前 |
| `5h 78%` / `7d 91%` | 最接近上限的方案額度視窗，低於 50% 不顯示，轉黃後附上重置時刻。API key 與雲端供應商沒有方案額度，因此不會出現 |

**warmline 不會靠測量 Claude Code 回覆得多快來猜快取是不是熱的。** 上面每一個判定
都是 Claude Code 交給狀態列的欄位：狀態來自 `prompt_cache.warm`，分桶來自 `ttl`，
時刻來自 `expires_at`，重建規模來自 `recache_tokens_if_cold`，方案額度來自
`rate_limits`。warmline 只負責排版與上色。它過去確實靠兩輪之間的間隔推論，
那套機制已經移除了。真正能據以決策的是兩個數字：**`(127k)` 是冷掉要付的代價**——
下一次快取寫入的大小，它把「值不值得保溫」從感覺變成數字；**`5h 78%`** 才是訂閱
使用者真正會用完的東西——中途打斷工作的不是美元，而是方案額度。`COLD`、`off` 與
`?` 是刻意分開的：「快取過期了」「根本沒有在做快取」「warmline 看不到」是三件不同的
事，把它們揉成一件，正是一個快取儀表開始說謊的起點。

過期時間始終是絕對的牆上時鐘，而不是倒數計時——凍住的倒數計時是*錯的*，凍住的時鐘
仍然是*真的*。從 `HOT` 到 `COLD` 的切換由 Claude Code 自己在過期的那一刻重繪狀態列
完成；安裝器寫入的 60 秒重新整理間隔不是為了它，而是為了**讓過期前的黃色警告在閒置
時也能被看到**。沒有它，這一行依然正確，只是不再提前警告你。

[全部欄位、顏色、疑難排解 →](docs/STATUSLINE.md)（英文）

### 冷著回來時

快取已經沒了；不論你接下來做什麼，那段脈絡都會再以未快取的價格處理一次。唯一的
問題是：這一次處理買到了什麼？

- **你仍然需要對話歷史 →** `/compact`。那次昂貴的處理反正都會發生；這樣至少讓它
  產出一份摘要，之後你可以便宜地攜帶它。
- **你的狀態寫在對話之外**（記憶檔、計畫文件、程式碼）**→** `/clear`。它連摘要
  那一次都省下來。
- **脈絡很小 →** 什麼都不做。重建 2 萬 token 很便宜。
- **絕不要在 `HOT` 時壓縮**，除非脈絡視窗已滿：那會摧毀你已付出約 2 倍代價建起來的
  快取。

[完整推理 →](docs/AUDIT.md#when-you-come-back-cold)（英文）

## 解釋與度量：稽核

狀態列上的一個 `HOT` 有用。看到你的工作階段在 8 週裡冷掉了 198 次，更有用。

`warmline audit` 依據 Claude Code 為每個已記錄 API 請求寫下的用量欄位評分——不像
狀態列，它沒有慢一輪的問題。`--all` 則對本機所有工作階段做同樣的事並排序。（它執行
的是已安裝的 `warmline-audit` 命令；兩種寫法都有效，已經寫好的腳本繼續可用。）以下
是某台機器 8 週歷史的真實輸出，為了讓範例穩定而一律按 `--price 3` 計價——不帶數值的
`--price` 會按專案求解你真實的單價：

```
$ warmline-audit --all --price 3
147 sessions under /Users/mb/.claude/projects  (13 more without API turns; ttl per session from its cache buckets, 60m fallback)

cache health  █████████████████████████░  95% hot  (10,394 of 10,921 turns)
cold events   198  (159 rebuilt, 39 ttl) -- 1.8% of all turns

start        project                 turns    hot  part  rebuilt   ttl  avoidable cold  share    premium
08-07 14:30  MimirBlue                 201    189     6        4     2       1,294,770    11%      $7.38
   ⋮
TOTAL                                10921  10394   329      159    39      12,134,109   100%     $69.16

where the cold came from
  unknown             ██████████████████████████  92 (39%)
  session start       █████████████████  59 (25%)
  auto-compact        ██████████  37 (16%)
  inactivity          █████████  31 (13%)

estimated avoidable premium ~$69.16  (top 5 sessions: $21.36, other 142: $47.81)
```

這就是可觀測性與裝飾性狀態列的差別：一個你能據以行動、或據以決定不行動的模式。

每個冷輪次都會在紀錄能**證明**的範圍內附上原因——`/compact`、`auto-compact`、
`model change`、`inactivity`——其餘的一律落進 `unknown`，而它是**殘差桶，不是結論**：
紀錄裡沒有留下證據，所以 warmline 拒絕給它安一個原因。Anthropic 記錄了好幾種紀錄
永遠看不見的前綴失效操作——改變思考強度、開啟 fast 模式、拒絕整個工具、啟用或停用
外掛、連接會把工具載入前綴的 MCP 伺服器，以及升級 Claude Code 本身——它們都會落到
這裡。工作階段中途編輯 CLAUDE.md 不會：Anthropic 把那一項列在*保住*快取的操作裡。在
這台機器上，`unknown` 占了冷事件的 39%，比所有壓縮加起來還多，而最糟的單一工作階段
獨占總量的 11%——這應當讀作「占比最大的部分尚未得到解釋」，那是去查的理由，而不是
診斷結論。（判定來自紀錄的用量，但 `COLD(rebuilt)` 與 `COLD(ttl)` 之間的劃分取決於
TTL——它按工作階段從各自的快取分桶紀錄中自動偵測。）

**這些金額是從你自己紀錄中的 token 數推算出的暴露估計，不是帳單資料**——warmline
從來看不到、也無法看到 Anthropic 實際向你收取多少。報告最後一行標為
`estimated avoidable premium`，其中的「avoidable（可避免）」僅指*排除每個工作階段
無可避免的第一次快取寫入之後*的部分：它統計到的一些情況在實務上並不可預防，例如
筆電休眠期間發生的 TTL 過期。

**warmline 不附帶價目表。** 寫死的價格會過時，而且在你從 Sonnet 換到 Opus 的那一刻
就是錯的。不帶數值的 `--price` 會直接求解你實際支付的基礎輸入單價：用 Claude Code
自己為該專案上一次工作階段記下的費用，配合每個 Claude 價格級距共有的倍率（輸出為
基礎輸入的 5 倍，1 小時快取寫入 2 倍，5 分鐘寫入 1.25 倍，熱讀取 0.1 倍）。`--all`
會用各專案自己的單價分別計價，每份報告都會寫明數字的來源；`--price N` 仍可覆寫。
輸出 token 從不進快取，因此稽核把它單獨列為一行，而不是假裝保溫能省下它。

稽核工具評判的是過去，而 **`warmline watch`** 呈現的是現在：所有工作階段溫度的即時
檢視，持續重新繪製直到 ctrl-c。桌面應用程式的工作階段也會出現在其中——它們雖然
無法繪製狀態列，寫出的卻是同樣的紀錄檔。

[完整講解、判定、原因、`--all`、`--live`、`--json` →](docs/AUDIT.md)（英文）

## 選用：保溫（Keep Warm）

以上全是觀測。Keep Warm 是選用的第四項能力：放在 `~/.claude/CLAUDE.md` 裡的一段
簡短指示，告訴代理在漫長而安靜的等待期間大約每 50 分鐘 ping 一次，好讓結果回來時
快取仍是溫的。

```sh
warmline keep-warm on        # 預設關閉；全域生效；可隨時撤銷
warmline keep-warm status    # ON／OFF／INCONSISTENT（結束碼 0／1／2）
```

它**不是常駐程式**——沒有 cron、沒有背景行程，也不會在執行中的 Claude Code 工作
階段之外送出任何請求。當背景任務已經免費把快取維持溫熱時它會跳過，代價很小時也
跳過，走 5 分鐘快取時同樣跳過——那需要每小時約 12 次 ping，比它能省下的 1.15 倍
重建還貴。工作一恢復就停止，並在大約 10 小時後放棄。每次 ping 都是一次針對你自己
方案的一般計費請求：它用幾次便宜的讀取換掉一次昂貴的重建，不繞過任何限制。

更好的是，只要這台機器看得到那份等待，就根本不必預約 ping：

```sh
warmline wait-for --pidfile /tmp/job.pid --until-cold
```

它會在任務結束**或**快取即將過期時返回，以先到者為準。期限讀自本工作階段自己的
紀錄，所以 12 分鐘就結束的任務一次 ping 也不用送。

[它是什麼、不是什麼、`wait-for`、免睡眠模式、限制與條款討論 →](docs/KEEP-WARM.md)（英文）

## 本機優先，是設計如此

warmline 只在你自己的機器上執行。它不向外傳送資料、不收集遙測、不需要帳號，除
`python3` 與 `bash` 之外沒有任何依賴。

它顯示的一切，都來自 Claude Code 已經寫在本機的資料：Claude Code 傳給狀態列的 JSON，
以及 `~/.claude/projects` 底下的工作階段紀錄。**warmline 觀察的是 Claude Code 在本機
公開的東西**——它對 Anthropic 的任何後端都沒有特殊存取權，也沒有任何要登入的地方。

## 在哪裡有效

| 前端 | 狀態列 | `warmline audit`／`watch` | keep-warm |
|---|---|---|---|
| 終端機 CLI | ✅ | ✅ | ✅ |
| 桌面應用程式（本機 Code 分頁） | ❌ | ✅ | ✅ |
| VS Code／JetBrains 面板 | ❌ | ✅ | ✅ |
| 雲端／Cowork 工作階段 | ❌ | ❌ | ❌ |

本機的圖形前端不會繪製自訂狀態列（[已提出的需求](https://github.com/anthropics/claude-code/issues/41456)），
但它們在本機跑同一個引擎、共用同一個 `~/.claude`、寫出同樣的紀錄檔，因此稽核工具、
`warmline watch` 與保溫策略在那裡照常運作。**唯一的例外是雲端／Cowork 工作階段：
warmline 的任何部分都碰不到它們。**

[完整對照表與驗證方式 →](docs/SURFACES.md)（英文）

## 實測證據

- **閒置 50 分鐘：溫的。70 分鐘：冷的。** 在無干擾環境下的雙臂探測中，50 分鐘後的
  探針讀回了完整的 71,312 token 前綴，70 分鐘後則重寫了 45,033 個 token。一小時的
  TTL 是真的，而且讀取會刷新它。
- **147 個工作階段、10,921 個輪次的稽核**（同一台機器）：95% 為 hot，但其中 39% 的冷
  事件**沒有歸到任何原因上**——那是紀錄未能提供證據的殘差，不是一個有名字的成因。

[資料、方法、如何重現 →](docs/MEASUREMENTS.md)（英文）

## 文件

詳細文件僅提供英文版。

| | |
|---|---|
| [Statusline](docs/STATUSLINE.md) | 全部欄位、顏色、疑難排解 |
| [Audit](docs/AUDIT.md) | 判定、原因歸因、`--all`、即時的 `watch` 檢視、"avoidable" 的定義 |
| [Keep Warm](docs/KEEP-WARM.md) | 策略、免睡眠模式（`warmline awake`）、限制與條款討論 |
| [Where it works](docs/SURFACES.md) | 終端機、桌面、IDE、SSH、雲端 |
| [Install](docs/INSTALL.md) | 安裝、更新、解除安裝、設定、Windows、測試 |
| [Measurements](docs/MEASUREMENTS.md) | 支撐每一項主張的實測資料 |
| [Changelog](CHANGELOG.md) | 帶標籤的版本 |

## 授權

[MIT](LICENSE)

## 請我喝杯咖啡 ☕

BTC: `bc1qjsvtd3dd44llyu4rwz2ucl4kp9wd9kvpsj6tk5`
