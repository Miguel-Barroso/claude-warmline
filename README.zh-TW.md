# claude-warmline

[English](README.md) | [日本語](README.ja.md) | **繁體中文** | [简体中文](README.zh-CN.md)

[![tests](https://github.com/Miguel-Barroso/claude-warmline/actions/workflows/test.yml/badge.svg)](https://github.com/Miguel-Barroso/claude-warmline/actions/workflows/test.yml)
[![version](https://img.shields.io/github/v/tag/Miguel-Barroso/claude-warmline?label=version)](https://github.com/Miguel-Barroso/claude-warmline/tags)
[![license](https://img.shields.io/github/license/Miguel-Barroso/claude-warmline)](LICENSE)

**為 Claude Code 提供提示快取的可觀測性與稽核。**

Claude Code 每一輪都會重新送出你的整段對話。讓這件事仍然負擔得起的，是伺服器端的
提示快取：只要它還在，每一輪就以大約正常輸入價格的 **0.1 倍**把對話*讀*回來；一旦
它消失，下一輪就得以約 **2 倍**的價格重建。這些 Claude Code 自己全都知道，你問它也會
說——`/usage` 會印出當前的快取狀態，從 v2.1.251 起狀態列收到的資料裡也帶著它。它沒
做的，是把這件事一直擺在你眼前，以及告訴你上個月所有工作階段因為冷掉一共付了多少。
warmline 兩件都做：把 Claude Code 自己的快取事實放到狀態列上，並在本機稽核歷史。它
只讀取 Claude Code 早已記錄在你機器上的資料，除 `python3` 與 `bash` 之外沒有任何
依賴，也不向外傳送任何資料。

![狀態列的五種狀態：帶過期時刻的綠色 cache HOT、接近過期時的黃色 cache HOT、紅色 cache COLD，以及 Claude Code 沒有快取資料時暗色的 cache off 與 cache ?](docs/statusline.svg)

## 它做什麼

**觀測（Observe）→ 解釋（Explain）→ 度量（Measure）→ 緩解（Mitigate）。**

| | | |
|---|---|---|
| **觀測** | `warmline` 狀態列 | 快取此刻正在發生什麼 |
| **解釋** | `warmline audit` | 某個工作階段裡發生了什麼，逐輪呈現 |
| **度量** | `warmline audit --all` | 本機所有工作階段中，風險暴露集中在哪裡 |
| **緩解** | `warmline keep-warm` | *選用*：預防其中一種可預防的失效模式 |

前三項是唯讀的觀測，也是本專案的重點。第四項需要主動開啟，預設關閉，而且刻意設有
邊界——見下方「選用：保溫」一節。

## 安裝

```sh
curl -fsSL https://raw.githubusercontent.com/Miguel-Barroso/claude-warmline/main/install.sh | bash

warmline status              # 目前安裝並啟用了什麼
warmline audit               # 本專案最近一個工作階段，逐輪查看
warmline audit --all         # 本機所有工作階段，排序呈現
warmline watch               # 所有工作階段的溫度，即時顯示，直到 ctrl-c
```

[安裝細節、參數、更新、Windows →](docs/INSTALL.md)（英文）

## 為什麼這很重要

Claude 在訊息之間不會記得任何事。你每按一次 Enter，Claude Code 就把*整段*對話重新
送出一次——系統提示、工具、它讀過的每個檔案、每一則回覆。在長工作階段裡，這輕易
就是每輪 10 萬以上的輸入 token。

提示快取吸收了這部分成本，但它會在**大約一小時無操作後**被拆掉；而只要對話開頭被
改寫，它也會立刻消失（`/compact` 與自動壓縮都會這樣做）。午餐後回到一個大工作階段，
你的下一則訊息就要重付全部的重建成本——偏偏在你最想要結果的時刻。

這裡的一切都是為 10 萬 token 以上的情況而存在。2 萬 token 冷掉了重建也很便宜。

## 觀測：狀態列

```
Fable 5 | claude-warmline | ctx 43% (168k) | cache HOT (cold ~13:04)
```

| 欄位 | 意義 |
|---|---|
| `ctx 43% (168k)` | 脈絡視窗使用率——超過 80% 轉黃，自動壓縮會從那裡開始改寫前綴 |
| `cache HOT (cold ~13:04)` | 快取的前綴是熱的，將在所示時間離開它的 TTL；過期前 15 分鐘內文字不變，只轉黃 |
| `cache HOT 5m` | 同上，但走的是 5 分鐘 TTL——用量額度、API key、雲端供應商。1 小時是常態，因此不標註 |
| `cache COLD` | 前綴已在 TTL 之外；下一輪會把它重新快取 |
| `cache off` | 提示快取被關閉，或這個供應商／閘道從不回報快取 token。這裡等再久都不會變熱 |
| `cache ?` | 沒有快取資料——v2.1.251 之前的 Claude Code，或本工作階段第一次 API 回應之前 |

**這些全都來自 Claude Code，而不是 warmline 的推論。** 從 v2.1.251 起，狀態列收到的
資料裡就帶著快取真實的冷熱、TTL 與過期時間戳，warmline 直接讀取它們，不再靠計算兩輪
之間的間隔去猜。`COLD`、`off` 與 `?` 是刻意分開的：「快取過期了」「根本沒有在做快取」
「warmline 看不到」是三件不同的事，把它們揉成一件，正是一個快取儀表開始說謊的起點。

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

`warmline audit` 依據 Claude Code 為每個已記錄 API 請求寫下的用量欄位評分——不像
狀態列，它沒有慢一輪的問題。`--all` 則對本機所有工作階段做同樣的事並排序。（它執行
的是已安裝的 `warmline-audit` 命令；兩種寫法都有效，已經寫好的腳本繼續可用。）以下
是某台機器 8 週歷史的真實輸出：

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
筆電休眠期間發生的 TTL 過期。輸入與輸出按不同單價分開計算，因為 Claude 就是這樣
計費的——`--price` 是模型的基礎**輸入**價（$/MTok，所有快取經濟都在這一側）；輸出
token 從不進快取，因此稽核把它單獨列為一行，而不是假裝保溫能省下它。

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
階段之外送出任何請求。當背景任務已經免費把快取維持溫熱時它會跳過，脈絡很小時也
跳過，工作一恢復就停止，並在大約 10 小時後放棄。每次 ping 都是一次針對你自己方案的
一般計費請求：它用幾次便宜的讀取換掉一次昂貴的重建，不繞過任何限制。

[它是什麼、不是什麼、`wait-for`、免睡眠模式、限制與條款討論 →](docs/KEEP-WARM.md)（英文）

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
