# claude-warmline

[English](README.md) | [日本語](README.ja.md) | [繁體中文](README.zh-TW.md) | **简体中文**

[![tests](https://github.com/Miguel-Barroso/claude-warmline/actions/workflows/test.yml/badge.svg)](https://github.com/Miguel-Barroso/claude-warmline/actions/workflows/test.yml)
[![version](https://img.shields.io/github/v/tag/Miguel-Barroso/claude-warmline?label=version)](https://github.com/Miguel-Barroso/claude-warmline/tags)
[![license](https://img.shields.io/github/license/Miguel-Barroso/claude-warmline)](LICENSE)

**在你的 Claude Code 会话即将醒来变得又慢又贵之前就知道——并阻止它发生。**

Claude Code 每发送一条消息都会重新发送整个对话。服务端的*提示词缓存*让这
一切便宜约 10 倍——直到它在大约一小时的静默后悄然过期，你的下一轮就要付出
双倍价格来重建它。claude-warmline 是针对这个问题的三个小工具，除 `python3`
和 `bash` 外没有任何依赖：

- **一个状态栏**：实时显示缓存状态（`HOT`/`COLD`），与模型、上下文用量和空闲时间并列
- **一个保温策略（keep-warm）**：让 agent 在长时间等待期间以低成本 ping 会话，使结果落在热缓存上
- **一个审计器**：逐轮为任意历史会话打分——什么保持了温热、什么变冷了、*为什么*、代价几何——加上 `--all` 后还能把本机上的每个会话按漏钱之处排名

![warmline 状态栏的三种状态：绿色的 cache HOT、黄色的 cache COLD(rebuilt)、红色的 cache COLD(ttl?)](docs/statusline.svg)

## 第一次接触？60 秒背景知识

Claude 在请求之间不记得任何东西。你每发送一条消息，Claude Code 都会重新发送
迄今为止的*整个*对话——系统提示词、工具、每个被读过的文件、每条回复。在一个
长会话里，每轮很容易就是 100k+ token 的输入，而且每次你都要为全部付费。

**提示词缓存**正是让这一切变得可负担的关键：提供商在服务端缓存你的对话前缀，
下一个请求以约 **0.1×** 正常输入价格*读取*它，而不是重新处理。首次写入缓存
的成本约为 **2×**——这笔溢价只付一次，随后在每个后续轮次中摊销。这就是为什么
一个繁忙的会话即使在 200k 上下文下也又快又便宜。

问题在于：缓存**会在一个 TTL 后过期——大约 1 小时的不活动**。午饭后回到一个
大会话，下一个请求会悄悄地在未缓存的状态下重新处理所有内容，并再次支付 2×
的重写溢价——恰恰在你想要结果的那一刻。缓存也会在*没有*任何空闲时间的情况下
死亡，只要对话前缀发生变化：`/compact` 会重写整个上下文，因此它总是触发一次
完整的重新缓存。

Claude Code 不会展示这些信息。warmline 让它可见。

## 读懂这一行

| 字段 | 含义 |
|---|---|
| `ctx 43% (168k)` | 上下文窗口利用率与对话中的输入 token 数 |
| `cache HOT` | 上一个请求从提示词缓存读取了数据（绿色） |
| `cache HOT (cold in 9m)` | 仍然温热，但空闲间隔距 TTL 已不足 15 分钟——现在就行动，否则就要付重建成本（黄色） |
| `cache COLD(rebuilt)` | 上一个请求发现前缀已冷并重新缓存了它（黄色） |
| `cache COLD(ttl?)` | *推断*：会话静默时间已超过 TTL，因此无论（陈旧的）usage 字段怎么说，缓存都已过期（红色） |
| `cache ?` | usage 字段不可用 |
| `gap 12m` | 距本会话上一次 API 轮次的分钟数（从 5m 起显示；空闲重绘不会重置它） |

颜色默认开启（Claude Code 会在状态栏中渲染 ANSI）；设置 `NO_COLOR` 或
`WARMLINE_NO_COLOR` 可将其禁用。

诚实的局限性：Claude Code 交给状态栏的是*上一个*请求的 usage 数字，因此
`HOT`/`COLD(rebuilt)` 滞后一轮；而 `COLD(ttl?)` 是基于时间的推断——所以带着
`?`。这一行也是拉取式的：脚本只在 Claude Code 重绘它时运行，因此在你的机器
睡眠期间，最后渲染的那一行——往往是届时已不真实的 `HOT`——会一直冻结在屏幕
上。warmline 保证的是：空闲时钟能在重绘中存活——只有真正的 API 轮次才会重置
它，因此你回来后的第一次重绘就已经显示 `COLD(ttl?)`——在你花掉任何钱之前——
并且在真的有请求落地之前一直保持这样。间隔按会话跟踪（`~/.claude/warmline-state/`
中的 stamp 文件），因此同一台机器上并发的 Claude Code 会话不会互相重置对方
的空闲时钟。

实际用途：大 `ctx` 上出现 `COLD(ttl?)`，标记的正是改变方向成本最低的时刻——
该往哪边跳，见下一节。

## 冷着回来：`/compact`、`/clear`，还是都不做？

大上下文上的 `COLD(ttl?)` 是一个岔路口。缓存已经没了；无论你接下来做什么，
那些上下文都要再以昂贵的未缓存价格处理一次。唯一的问题是，这一次不可避免的
昂贵处理能给你换来什么：

- **你仍然需要对话历史 → `/compact`。** 压缩必须把整个对话读一遍才能总结。
  在热缓存上这次读取本来很便宜——但它同时会摧毁一个你已经付了 2× 建起来的
  缓存，这就是为什么在 `HOT` 时压缩是时机最糟糕的操作（除非你的上下文窗口
  已用尽、别无选择）。在冷缓存上，这次昂贵的处理反正在你下一条消息时就会发
  生——压缩只是把它引导为生成一份小小的总结，此后你缓存并携带的是几千 token
  而不是 100k+。这就是为什么 `/compact` 恰恰在缓存已死时收益最大。
- **你的状态已写在对话之外 → `/clear`。** 如果你继续工作所需的东西存在于记
  忆文件、计划文档，或代码和 git 历史本身之中，`/clear` 连总结那一遍都省了——
  再也没有任何东西需要付费去读旧上下文。而一个全新会话并*不会*把所有内容重
  新吸回来：它的前缀只是系统提示词、你的 CLAUDE.md 和一行记忆索引——各个记
  忆文件和项目文件只在变得相关时才会被读取。这种有针对性的重读会消耗新的输
  入 token，但几乎总是远少于对一个 100k+ 对话做一次总结。
- **小上下文 → 什么都不做。** 20k token 变冷的重建成本很低。这个指示器和保
  温策略都是为 100k+ 的情况而存在的。

## 安装

```sh
curl -fsSL https://raw.githubusercontent.com/Miguel-Barroso/claude-warmline/main/install.sh | bash
```

或者从检出的仓库安装：

```sh
git clone https://github.com/Miguel-Barroso/claude-warmline.git
cd claude-warmline
./install.sh
```

安装器会把 `statusline.py` 复制到 `~/.claude/warmline-statusline.py` 并将其接入
`~/.claude/settings.json`（会先备份你之前的 `settings.json`；未加 `--force` 时
绝不会替换已存在的自定义状态栏）。Claude Code 通常会在几秒内识别它——如果没
有，请重启会话。

| 参数 | 效果 |
|---|---|
| `--keep-warm` | 同时把保温策略块追加到 `~/.claude/CLAUDE.md` |
| `--force` | 替换已存在的非 warmline 状态栏 |
| `--uninstall` | 移除脚本、settings 条目、状态文件和策略块 |

需要 `python3`（仅标准库）和 `bash`。

## 实测结果（不是建模推算）

以上所有说法都可以对照真实转录验证——Claude Code 会在会话的 `.jsonl` 文件中
为每个 API 轮次记录 `cache_read_input_tokens` 和 `cache_creation_input_tokens`，
[`warmline-audit`](#审计过往会话) 会给它们打分。以下来自一个真实的 13 小时
编排会话（2026-08-18，约 300k 上下文，带后台 CI 监视器的 merge-queue 值守）：

- **260 个 API 轮次：255 HOT、1 COLD(rebuilt)、1 COLD(ttl)**——从缓存读取了
  45.9M token；只有 99k token 在冷状态下被重新缓存。
- 每约 9 分钟到达一次的后台任务通知让缓存连续四小时保持温热，**每次唤醒仅
  约 400 token 的缓存写入**（同期读取量从 150k 增长到 317k）。**只要有后台
  工作在进行，它的通知就会免费保持缓存温热**——不需要任何策略。
- 那一次 `COLD(ttl)` 出现在一次 6 小时的整夜静默之后——机器在睡眠，所以什么
  也不可能触发。**任何定时唤醒都无法在合上的笔记本盖下存活**（在 macOS 上，
  `caffeinate` 是计划中长时间等待的应对办法）。
- 那一次 `COLD(rebuilt)` 紧跟在 `/compact` 之后：活跃状态下几分钟内就发生了
  一次完整的 58k token 重新缓存。前缀失效与 TTL 过期是两种不同的失败模式，
  这正是状态栏区分它们的原因。
- 无头探针确认了 TTL 档位：Claude Code 以 `ephemeral_1h`（1 小时 TTL）写入
  缓存，恢复的会话能读回它的完整前缀（参考探针中读取 33,614 token、写入
  56 token）。
- TTL 边界本身在一次洁净室双臂实验中测得（隔离的无头会话、无 MCP 服务器、
  冻结的环境）：在完全静默 **50 分钟**后，探针从缓存读取了完整的 71,312
  token 前缀、只写入 56 token；**70 分钟**后，一个完全相同的会话发现缓存已
  消失，重写了其内容的全部 45,033 token。50 分钟时是热的、70 分钟时是冷的——
  1 小时 TTL 是真实存在的，而保温 ping 间隔（约 50 分钟）安全地落在其内。
- 冷臂同时演示了 ping 为什么有效：**读取会刷新 TTL**。它的探针仍然发现共享
  的系统块是温热的，因为另一臂在 20 分钟前读过那个块。保温 ping 正是这样一
  次刷新，作用于你的整个前缀。
- 纵观这台机器的全部历史（8 周内 149 个会话），
  [`warmline-audit --all`](#钱从哪里漏掉--all) 按 Sonnet 基础定价估算的可避
  免溢价总额为 **~$64**——并且把 43 次缓存重建归因于压缩，而 **87 次归因于
  无法解释的前缀漂移**。漏钱的地方很少在你以为的位置。
- 同一实验早前一次刻意“不干净”的运行揭示了一种更微妙的失败模式：无头
  `--resume` 会重新生成整个系统提示词，因此轮次之间的 git 状态漂移、MCP 服
  务器可用性变化或被编辑过的 CLAUDE.md 会让前缀悄然分叉——分叉点之后的一切
  都要按全价重新缓存。**前缀稳定性与 TTL 同样重要**：如果一个会话的前缀在
  轮次之间不断变动，任何保温 ping 都救不了它。

## 保温策略

`--keep-warm` 会在你的全局 `~/.claude/CLAUDE.md` 末尾追加一个简短的、以标记
分隔的块（见 [`keep-warm.md`](keep-warm.md)），指示 agent：当它启动的后台工
作预计超过约 45 分钟、且上下文可观时，安排一次约 50 分钟后的唤醒；醒来时若
工作仍在进行就重新安排，否则继续——并且绝不让唤醒比等待活得更久。这样结果就
总是落在热缓存上。

它什么时候真正有用——什么时候没用：

- **后台任务运行期间是多余的。** 它们的完成通知已经能在 TTL 之内轻松唤醒会
  话（上文已实测）。策略会告诉 agent 在这种情况下跳过安排。
- **当会话真正安静下来时才有价值**——在没有本地监视器的情况下等待远程 CI，
  或者一个人带着 100k+ 的温热上下文走开、并打算回来。每次 ping 的成本约为
  你上下文的 0.1×（计入缓存读取额度），而冷重写约为 2×，因此只要你会回来，
  保温对长达约 10–12 小时的空闲时段都是划算的。策略会刻意跳过小上下文——
  那种情况下变冷的重建成本本来就低。
- **会被主机睡眠击败。** 唤醒无法在睡眠的机器上触发。macOS 上计划长时间等
  待时：`caffeinate -is`（或接上电源并保持屏幕盖打开）。

工具可用性因 Claude Code 构建版本而异：`ScheduleWakeup` 可能不存在，或者存
在但受运行时门控（在动态 `/loop` 会话之外会被拒绝）。在这类构建上，该块要
么处于惰性状态，要么 agent 会回退到定时的循环提示——`/loop 50m <ping>` 通过
cron 实现同样的唤醒节奏。

## 审计过往会话

```sh
./warmline-audit                      # latest session of the current project
./warmline-audit path/to/session.jsonl
./warmline-audit --ttl 5 --json       # short-TTL setups, machine-readable
./warmline-audit --price 3            # add a dollar estimate, given your
                                      # model's base input price per MTok
./warmline-audit --all --price 3      # every session on this machine,
                                      # ranked by estimated avoidable premium
```

每个 API 轮次打印一行——时间戳、空闲间隔、缓存读/写 token 数、判定——外加一
份总结，说明有多少 token 在冷状态下被重新缓存。冷的（以及被大量重写的）轮
次会在转录确实能支持时带上**原因（cause）**：

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

原因是归因，不是猜测。`/compact` 与 `auto-compact` 表示转录中在这一轮与上
一轮之间存在一个结构化的压缩边界标记（压缩往往会让共享前缀的头部保持温热，
因此它通常表现为一个带归因的 `PARTIAL`，而不是一次完全的冷重建）。
`model change` 表示记录的模型与上一轮不同。`session start` 是每个会话都必
须支付的第一次缓存写入。`inactivity+compact` 标注的是含糊情形：长间隔与压
缩各自都能解释这次重建——两者都不作断言。其余一切都诚实地标为 `unknown`：
实践中主要是转录无法证明的前缀漂移（被编辑的 CLAUDE.md、变化的 git 状态、
MCP 可用性）。

与状态栏（由构造决定滞后一轮）不同，审计是权威的：它读取每个请求记录下的
usage。用它来验证保温策略是否真的让你保持了温热，或者查明一次 `/compact`
或一夜的间隔究竟花了多少钱。

### 钱从哪里漏掉？`--all`

`--all` 会审计 `~/.claude/projects` 下（或你传入的目录下）的每个会话，并为
每个会话打印一行，按**可避免的冷 token**排名——即在冷状态下重新缓存的
token，扣除每个会话不可避免的首次写入。来自这台机器 8 周历史的真实输出：

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

这个美元数字是什么——以及不是什么：加上 `--price <base $/MTok>` 后，premium
列是**估算的可避免溢价**——可避免的冷 token × 1.9 × 你的模型的基础输入价格
（一次冷重缓存按约 2× 计费；它所取代的那次热读取本应按约 0.1× 计费）。它
来自你的转录中记录的 token 计数，而不是账单数据，并且忽略了会话内不同模型
的价格差异以及子 agent 的转录（独立文件、独立前缀，有意排除）。把它当作排
名信号，而不是发票。

怎么读它：排在顶部、`ttl` 计数很大的会话是保温的候选——那是走开造成的损失。
`rebuilt`/`unknown` 计数大意味着前缀变动：有什么东西在轮次之间修改了对话前
缀。大量 `auto-compact` 意味着会话经常撞上上下文上限，此时更早、更主动地压
缩（见上文）反而更便宜。在这台机器上，诚实的结论是：无声的前缀漂移
（`unknown 87`）重建的缓存比压缩（43 次）还多——漏钱的地方很少在你以为的位置。

## 配置

| 环境变量 | 默认值 | 含义 |
|---|---|---|
| `WARMLINE_TTL_MIN` | `60` | 提示词缓存 TTL，单位为分钟（短 TTL 环境可设为 `5`） |
| `WARMLINE_STATE_DIR` | `~/.claude/warmline-state` | stamp/状态目录 |
| `WARMLINE_NO_COLOR` | 未设置 | 若设置（或设置了 `NO_COLOR`），输出纯文本、不含 ANSI 颜色 |
| `WARMLINE_DEBUG` | 未设置 | 若设置，保留最后一次原始状态栏载荷以供检查 |

在 Claude Code 启动所在的环境中设置这些变量，或写进 `~/.claude/settings.json`
的 `env` 块。`WARMLINE_TTL_MIN` 同时被状态栏和 `warmline-audit` 遵循。

## 兼容性与更新

已针对 Claude Code **2.1.233**（写作时的当前版本）验证。状态栏的 JSON 字段
对照真实的 harness 载荷做过检查，`warmline-audit` 能解析这台机器上存在的所
有转录格式——Claude Code 版本 **2.1.181 到 2.1.233**、149 个会话、零格式错
误条目。已处理一个已知的格式怪癖：某些版本在约 28% 的 assistant 条目上省略
`requestId`，因此审计按 `message.id` 对 API 请求去重。

**更新：**安装器就是更新器。重新运行同一条 `curl | bash` 一行命令（或在拉
取过的检出中运行 `./install.sh`）——它能识别自己的状态栏并原地替换、无需
`--force`，而且每次运行都会备份你的 `settings.json`。
[CHANGELOG.md](CHANGELOG.md) 记录了各个标签发布之间的变更。

**Windows：**状态栏和审计器是纯标准库 Python，不关心操作系统；只有安装器和
测试套件是 bash。手动安装：

1. 把 `statusline.py` 复制到 `%USERPROFILE%\.claude\warmline-statusline.py`
2. 在 `%USERPROFILE%\.claude\settings.json` 中设置
   `"statusLine": {"type": "command", "command": "python C:\\Users\\you\\.claude\\warmline-statusline.py"}`
3. 以 `python warmline-audit [args]` 运行审计器

ANSI 颜色在 Windows Terminal 中渲染正常。一个经过测试的 `install.ps1` 会是
一份受欢迎的贡献——依照本项目的理念，我们不发布自己无法测试的东西。

## 测试

```sh
./test.sh
```

对脚本回放具有代表性的状态栏载荷（热、冷重建、TTL 过期、稀疏、垃圾数据、
并发会话隔离、空闲重绘不重置时钟、新轮次覆盖 TTL 推断、过期倒计时、ANSI
颜色），对 `warmline-audit` 回放一份合成转录（包括 `--price` 估算和每一种
冷原因归因，含那个含糊的情形），并对 `--all` 回放一个合成的多项目语料库
（发现、子 agent 排除、排名、总计、JSON）。同一套件在每次推送时都在 CI 中
运行。

## 许可证

[MIT](LICENSE)

## 请我喝杯咖啡 ☕

BTC: `bc1qjsvtd3dd44llyu4rwz2ucl4kp9wd9kvpsj6tk5`
