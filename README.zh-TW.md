# claude-warmline

[English](README.md) | [日本語](README.ja.md) | **繁體中文** | [简体中文](README.zh-CN.md)

[![tests](https://github.com/Miguel-Barroso/claude-warmline/actions/workflows/test.yml/badge.svg)](https://github.com/Miguel-Barroso/claude-warmline/actions/workflows/test.yml)
[![version](https://img.shields.io/github/v/tag/Miguel-Barroso/claude-warmline?label=version)](https://github.com/Miguel-Barroso/claude-warmline/tags)
[![license](https://img.shields.io/github/license/Miguel-Barroso/claude-warmline)](LICENSE)

**看見 Claude Code 何時悄悄重新處理你的整段對話——並阻止其中可以避免的部分。**

為 Claude Code 隱藏的脈絡／快取經濟提供輕量級可觀測性：一條狀態列、一個稽核工具，
以及一份選用的保溫策略。除了 `python3` 和 `bash` 之外沒有任何依賴；不會向外傳送
任何資料——一切都讀自 Claude Code 早已記錄在你機器上的資料。

![狀態列的三種狀態：綠色 cache HOT 搭配 keep-warm on、黃色 cache COLD(rebuilt)、紅色 cache COLD(ttl?) 搭配 keep-warm off](docs/statusline.svg)

## 30 秒版本

Claude 在訊息之間不會記得任何東西。你每按一次 Enter，Claude Code 就把*整段*對話
重新送出一次——系統提示、工具、它讀過的每個檔案、每一則回覆。在長對話裡，這輕易
就是每一輪 10 萬以上的輸入 token。

讓這件事仍然負擔得起的，是伺服器端的**提示快取**。可以把它想成 Claude 已經為你的
對話架好的工作台：只要工作台還在，每則新訊息都以大約正常輸入價格的 **0.1 倍**
*讀取*它。架設成本大約 **2 倍**——付一次，之後攤提到每一輪。

問題在於：這個工作台會在**大約一小時沒有動作後**被靜靜拆掉；只要對話開頭被改寫，
它也會立刻消失（`/compact` 一定會觸發整個重建）。午餐後回到一個大型工作階段，
你的下一則訊息就要用 2 倍價格重付全部——偏偏就在你最想要結果的時刻。

Claude Code 完全不會顯示這些。warmline 讓它可見——並協助你避免可以避免的部分。

## 快速開始

```sh
curl -fsSL https://raw.githubusercontent.com/Miguel-Barroso/claude-warmline/main/install.sh | bash

warmline status              # 目前安裝與啟用了什麼
warmline keep-warm on        # 選用：預防可避免的冷啟動
```

接著照常使用 Claude Code——狀態列會即時顯示快取狀態。想知道某個工作階段
（或全部）實際花了多少時：

```sh
warmline-audit               # 這個工作階段，逐輪檢視
warmline-audit --all         # 所有工作階段，依漏財多寡排序
```

[安裝細節、旗標、更新、Windows →](docs/INSTALL.md)

## 如何讀這一行

```
Fable 5 | claude-warmline | ctx 43% (168k) | cache HOT | gap 12m | keep-warm on
```

| 欄位 | 意義 |
|---|---|
| `ctx 43% (168k)` | 脈絡視窗使用率，以及對話中的輸入 token 數 |
| `cache HOT` | 上一個請求從提示快取讀取（綠色） |
| `cache HOT (cold in 9m)` | 仍然溫的，但距 TTL 不到 15 分鐘——現在行動，否則付重建（黃色） |
| `cache COLD(rebuilt)` | 上一個請求發現前綴已冷，並重新快取了它（黃色） |
| `cache COLD(ttl?)` | *推論*：安靜的時間超過 TTL，因此快取已經過期（紅色） |
| `gap 12m` | 距離這個工作階段上一次 API 輪次的分鐘數；閒置重繪不會重設它 |
| `keep-warm on` | [保溫策略](#keep-warm)是否已安裝——`off` 為暗色，區塊損壞時顯示 `?` |

兩點誠實的但書：Claude Code 交給狀態列的用量數字屬於*上一個*請求，所以
`HOT`／`COLD(rebuilt)` 會落後一輪；而 `COLD(ttl?)` 是基於時間的推論——所以才有那個
`?`。warmline 保證的是閒置計時能跨越重繪存活，因此你回來後的第一次重繪就已經顯示
`COLD(ttl?)`——在你花掉任何東西之前。

[所有欄位、顏色、gap 機制、疑難排解 →](docs/STATUSLINE.md)（英文）

## 冷著回來時：`/compact`、`/clear`，還是什麼都不做？

大型脈絡上的 `COLD(ttl?)` 是一個岔路。快取已經沒了；不論你接下來做什麼，那段脈絡
都會再以昂貴的未快取價格處理一次。唯一的問題是：這一次無可避免的處理買到了什麼？

- **你仍然需要對話歷史 → `/compact`。** 壓縮必須把整段對話讀過一次才能摘要。快取
  還溫著的時候這次讀取很便宜——但它同時會摧毀你已付 2 倍代價建起來的快取，所以在
  `HOT` 時壓縮是時機最差的一步（除非脈絡視窗已滿，別無選擇）。快取已冷時，那次昂貴
  的處理反正也會發生在你的下一則訊息上——壓縮只是把它改導向產出一份小摘要，從此你
  快取並攜帶的是幾千個 token，而不是 10 萬以上。`/compact` 效益最大的時刻，正是
  快取已經死掉的時候。
- **你的狀態寫在對話之外 → `/clear`。** 如果你需要的東西存在記憶檔案、計畫文件、
  程式碼與 git 歷史裡，`/clear` 連摘要那一次都省掉——沒有人再付錢去讀舊脈絡。新
  工作階段的前綴只有系統提示、你的 CLAUDE.md 和記憶索引；檔案只在真正需要時才重讀，
  這幾乎總是比對 10 萬以上 token 的對話做一次摘要便宜得多。
- **脈絡很小 → 什麼都不做。** 2 萬 token 冷掉了也很便宜重建。這裡的一切都是為了
  10 萬以上的情況而存在。

## 錢漏到哪裡去了

`warmline-audit` 會為工作階段裡每一個記錄下來的 API 請求評分——沒有延遲、不靠推論。
`--all` 則把機器上所有工作階段依**可避免的冷 token**排名：也就是在每個工作階段
無可避免的第一次寫入之後，所有在冷狀態下重新快取的量。以下是某台機器 8 週歷史的
真實輸出：

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

每個冷輪次都會在紀錄檔能證明的範圍內附上原因——`/compact`、`auto-compact`、
`model change`、`inactivity`——證明不了的就誠實標為 `unknown`（實務上多半是前綴
漂移：被編輯的 CLAUDE.md、變動的 git 狀態、MCP 是否可用）。請注意這裡的意義：
無聲的漂移重建的快取比壓縮還多。漏財之處，往往不在你以為的地方。

這個金額是從你自己紀錄檔中的 token 數推估出來的，絕不是帳單資料。

[完整導讀、判定、原因、`--all`、`--json` →](docs/AUDIT.md)（英文）

## Keep Warm

以上全都是*觀測*。Keep Warm 是選用的*預防*另一半：放在 `~/.claude/CLAUDE.md` 的
一段簡短指示，告訴代理在漫長而安靜的等待期間大約每 50 分鐘 ping 一次，好讓結果
回來時快取仍然是溫的。

```sh
warmline keep-warm on        # 全域；跨工作階段與更新持續有效
warmline keep-warm status    # ON / OFF / INCONSISTENT（結束碼 0 / 1 / 2）
warmline keep-warm off
```

它**不是常駐程式**——沒有 cron、沒有行程，也不會在運行中的 Claude Code 工作階段
之外送出任何請求。當背景任務已經免費把快取維持溫熱時它會跳過，脈絡很小時也跳過，
工作一恢復就停止，並在大約 10 小時後放棄。一次 ping 的成本約為脈絡的 0.1 倍；
它所預防的重建則是約 2 倍。

[它是什麼、不是什麼、何時無法運作、條款討論 →](docs/KEEP-WARM.md)（英文）

## 在哪些地方有效

| 前端 | 狀態列 | `warmline-audit` | keep-warm |
|---|---|---|---|
| 終端機 CLI | ✅ | ✅ | ✅ |
| 桌面應用程式（本機 Code 分頁） | ❌ | ✅ | ✅ |
| VS Code／JetBrains 面板 | ❌ | ✅ | ✅ |
| 雲端／Cowork 工作階段 | ❌ | ❌ | — |

圖形前端不會繪製自訂狀態列（[已提出的需求](https://github.com/anthropics/claude-code/issues/41456)），
但它們跑的是同一個引擎、共用同一個 `~/.claude`、寫出同樣的紀錄檔，因此稽核工具與
保溫策略在那裡照常運作。若你在桌面應用程式裡也想要這條量表，就在整合終端機中執行
`claude`。

[完整對照表與驗證方式 →](docs/SURFACES.md)（英文）

## 實測，而非模型

- **閒置 50 分鐘：溫的。70 分鐘：冷的。** 在無干擾環境下的雙組探測中，50 分鐘後的
  探針讀回了完整的 71,312 token 前綴，70 分鐘後則重寫了 45,033 個 token。一小時的
  TTL 是真的，而且讀取會刷新它——這正是 ping 有效的原因。
- **背景工作會免費維持快取溫熱。** 每約 9 分鐘一次的任務通知，讓 30 萬 token 的
  脈絡連續四小時保持 HOT，每次喚醒只寫入約 400 個 token。所以 keep-warm 會跳過這種
  情況。
- **闔上筆電時沒有任何喚醒能存活。** 在一段 13 小時、260 輪的工作階段中，唯一一次
  TTL 過期發生在機器沉睡的 6 小時夜間靜默之後。
- **前綴穩定性與 TTL 同樣重要。** 漂移的系統提示（被編輯的 CLAUDE.md、變動的 git
  狀態、MCP 是否可用）會讓分歧點之後的一切重新快取，任何 ping 都救不了。

[數據、方法、如何重現 →](docs/MEASUREMENTS.md)（英文）

## 文件

詳細文件僅提供英文版。

| | |
|---|---|
| [Statusline](docs/STATUSLINE.md) | 所有欄位、顏色、gap 機制、疑難排解 |
| [Audit](docs/AUDIT.md) | 判定、原因歸因、`--all`、"avoidable" 的定義 |
| [Keep Warm](docs/KEEP-WARM.md) | 策略、其限制與條款討論 |
| [Where it works](docs/SURFACES.md) | 終端機、桌面、IDE、SSH、雲端 |
| [Install](docs/INSTALL.md) | 安裝、更新、解除安裝、設定、Windows、測試 |
| [Measurements](docs/MEASUREMENTS.md) | 支撐每一項主張的實測資料 |
| [Changelog](CHANGELOG.md) | 帶標籤的版本 |

## 授權

[MIT](LICENSE)

## 請我喝杯咖啡 ☕

BTC: `bc1qjsvtd3dd44llyu4rwz2ucl4kp9wd9kvpsj6tk5`
