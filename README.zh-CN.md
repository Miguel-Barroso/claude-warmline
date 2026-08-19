# claude-warmline

[English](README.md) | [日本語](README.ja.md) | [繁體中文](README.zh-TW.md) | **简体中文**

[![tests](https://github.com/Miguel-Barroso/claude-warmline/actions/workflows/test.yml/badge.svg)](https://github.com/Miguel-Barroso/claude-warmline/actions/workflows/test.yml)
[![version](https://img.shields.io/github/v/tag/Miguel-Barroso/claude-warmline?label=version)](https://github.com/Miguel-Barroso/claude-warmline/tags)
[![license](https://img.shields.io/github/license/Miguel-Barroso/claude-warmline)](LICENSE)

**看见 Claude Code 何时在悄悄重新处理你的整个对话——并阻止其中可以避免的部分。**

面向 Claude Code 隐藏的上下文/缓存经济学的轻量可观测性工具：一个状态栏、
一个审计器，以及一个可选的保温（keep-warm）策略。除 `python3` 和 `bash`
外没有任何依赖；不向任何地方发送数据——一切都读取自 Claude Code 本来就
记录在你机器上的数据。

![warmline 状态栏的三种状态：绿色的 cache HOT、黄色的 cache COLD(rebuilt)、红色的 cache COLD(ttl?)](docs/statusline.svg)

## 30 秒版本

Claude 在消息之间不记得任何东西。你每按一次回车，Claude Code 都会重新发送
迄今为止的*整个*对话——系统提示词、工具、每个被读过的文件、每条回复。在一
个长会话里，这很容易就是每轮 100k+ token 的输入。

让这一切变得可负担的，是服务端的**提示词缓存**。可以把它想成 Claude 已经
为你的对话搭好的一个工作台：只要工作台还在，每条新消息都以约 **0.1×** 的
正常输入价格*读取*它。首次搭建的成本约为 **2×**——只付一次，随后在每个轮
次中摊销。这就是为什么一个繁忙的会话即使在 200k 上下文下也又快又便宜。

问题在于：这个工作台会在**大约一小时的不活动**之后被悄悄拆掉。午饭后回到
一个大会话，你的下一条消息就要以 2× 的价格把它全部重建——恰恰在你想要结果
的那一刻。它也会在*没有*任何空闲时间的情况下被拆掉，只要对话的开头被改写：
`/compact` 会重新整理整个工作台，因此它总是触发一次完整的重建。

Claude Code 不会展示这些。warmline 让它可见——并帮你阻止其中可以避免的部分。

## 快速开始

```sh
curl -fsSL https://raw.githubusercontent.com/Miguel-Barroso/claude-warmline/main/install.sh | bash

warmline keep-warm on        # optional: prevent avoidable cold starts
warmline keep-warm status    # is it on?
```

然后正常使用 Claude Code——状态栏会实时显示缓存状态。当你想知道某个会话
（或所有会话）实际付出了什么代价：

```sh
warmline-audit               # this session, turn by turn
warmline-audit --all         # every session, ranked by where the money leaked
```

## warmline 回答什么

| | 问题 |
|---|---|
| **状态栏** | 现在正在发生什么？（`cache HOT` / `COLD`，实时） |
| **`warmline-audit`** | 这个会话里逐轮发生了什么？ |
| **`warmline-audit --all`** | 我的用量在所有会话中从哪里漏钱？ |
| **原因归因** | 缓存*为什么*变冷——空闲、`/compact`，还是漂移？ |
| **keep-warm**（可选） | 我能阻止那些可避免的冷启动吗？ |

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

什么装到哪里：`statusline.py` → `~/.claude/warmline-statusline.py`，并接入
`~/.claude/settings.json`（会先备份；未加 `--force` 时绝不会替换已存在的自
定义状态栏）；`warmline` 和 `warmline-audit` 两个命令 → `~/.local/bin/`
（可用 `WARMLINE_BIN_DIR` 覆盖）；保温策略文本 →
`~/.claude/warmline-keep-warm.md`。Claude Code 通常会在几秒内识别状态栏——
如果没有，请重启会话。

如果 `~/.local/bin` 不在你的 `PATH` 上，安装器会明确说出来，并打印需要添加
的那一行（`export PATH="$HOME/.local/bin:$PATH"`）——它自己绝不会编辑你的
shell 启动文件。

| 参数 | 效果 |
|---|---|
| `--keep-warm` | 安装时的快捷方式，等同于 [`warmline keep-warm on`](#keep-warm) |
| `--force` | 替换已存在的非 warmline 状态栏 |
| `--uninstall` | 移除安装器添加的一切，包括策略块 |
| `--help` | 用法说明 |

需要 `python3`（仅标准库）和 `bash`。要在 `curl` 形式下传参：
`curl -fsSL …/install.sh | bash -s -- --keep-warm`。

**安装器负责安装 warmline，`warmline` 命令负责控制它。**任何时候，一条命令
就能回答"warmline 在这台机器上正在做什么？"：

```
$ warmline status
claude-warmline status  (config: /Users/mb/.claude)
  statusline  ON   /Users/mb/.claude/warmline-statusline.py
  keep-warm   OFF  (enable: warmline keep-warm on)
  auditor     ON   /Users/mb/.local/bin/warmline-audit
  ttl         60m (default)
```

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
它，因此你回来后的第一次重绘就已经显示 `COLD(ttl?)`——在你花掉任何钱之前。
间隔按会话跟踪（`~/.claude/warmline-state/` 中的 stamp 文件），因此并发会话
不会互相重置对方的空闲时钟。

实际用途：大 `ctx` 上出现 `COLD(ttl?)`，标记的正是改变方向成本最低的时刻——
见「[冷着回来](#冷着回来compactclear还是都不做)」一节。

## 审计过往会话

```sh
warmline-audit                      # latest session of the current project
warmline-audit path/to/session.jsonl
warmline-audit --ttl 5 --json       # short-TTL setups, machine-readable
warmline-audit --price 3            # add dollar estimates, given your
                                    # model's base input price per MTok
warmline-audit --all --price 3      # every session on this machine,
                                    # ranked by estimated avoidable premium
```

（已安装到 `~/.local/bin/`；从检出的仓库运行则用 `./warmline-audit`。
`warmline audit …` 是同一回事。）

与状态栏（由构造决定滞后一轮）不同，审计是权威的：它为每个记录下来的 API
请求打分。一个真实会话：

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

从上往下读：

- **每一行是一个 API 请求。** `gap` 是它之前的空闲时间；`cache read`/`cache
  write` 是它从缓存读取、或重新写入缓存的 token 数。
- 那个 `/compact` 行是一次带有确证原因的 **`COLD(rebuilt)`**：转录中恰好在
  它之前有一个结构化的压缩边界标记。没有任何空闲时间——仅前缀改写本身就杀
  死了缓存。紧随其后的 `PARTIAL` 也很典型：压缩往往会让共享前缀的头部保持
  温热，因此下一轮在重写其余部分的同时还能读回一些缓存。
- 那个 `6h12m` 行才是昂贵的那次：整夜静默，缓存过期，清晨的第一条消息以 2×
  的价格重写了 58k token。而那个间隔之内*还*发生过一次压缩，所以审计器不去
  猜测，而是标为 **`inactivity+compact`**——两者都可能解释这次重建。
- **cache health 条**是运行在热状态下的轮次占比。它下面是判定统计，然后是
  每个冷轮次*为什么*发生。（会话的第一次缓存写入会被标为 `session start`，
  永远不计入可避免；这个会话恢复时缓存还是温热的，所以它一次都没有。）
- 最后一行 **estimated avoidable premium（估算的可避免溢价）**，是*潜在*可
  避免的冷重缓存*相比*同样 token 的热读取多花的钱（一次冷重缓存按约 2× 计
  费；它取代的那次热读取本应按约 0.1× 计费——差额为 1.9×）。它是来自记录下
  来的 token 计数的估算，永远不是账单数据——见
  「[「可避免」的精确含义](#钱从哪里漏掉--all)」。

原因是归因，不是猜测：`/compact` 与 `auto-compact` 来自转录中的结构化标记，
`model change` 来自记录的模型，`inactivity+compact` 标注两者皆可解释的含糊
情形，其余一切都诚实地标为 `unknown`——实践中主要是转录无法证明的前缀漂移
（被编辑的 CLAUDE.md、变化的 git 状态、MCP 可用性）。

### 钱从哪里漏掉？`--all`

`--all` 会审计 `~/.claude/projects` 下（或你传入的目录下）的每个会话，每个
会话一行，按**可避免的冷 token**排名——这个词在这里有精确的含义，就定义在
输出的正下方。来自这台机器 8 周历史的真实输出：

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

**「可避免」的精确含义。**每个会话都必须为它的第一次缓存写入付费：一个对话
总得先被缓存一次，之后才谈得上便宜地读回。warmline 从不把这一次计算在内。
它计为*可避免*的，是在那之后每一个在冷状态下被重新缓存的 token——由 TTL 过
期、压缩或前缀漂移引起的重建，而不同的时机（一次保温 ping、一次更早的主动
`/compact`、一个稳定的前缀）*本可能*避免它们。因此这个数字是暴露程度的估
算，不是实际浪费掉的钱：其中一部分在实践中无法避免（笔记本睡眠期间的 TTL
过期也被计为「可避免」，尽管那时没有任何 ping 能够触发），而且全部数字都来
自你转录中记录的 token 计数——warmline 从不知道、也无法知道 Anthropic 实际
向你的账户收了多少钱。

怎么读它：排在顶部、`ttl` 计数很大的会话是保温的候选——那是走开造成的损失。
`rebuilt`/`unknown` 计数大意味着前缀变动：有什么东西在轮次之间改写了对话前
缀。大量 `auto-compact` 意味着会话经常撞上上下文上限，此时更早、更主动地压
缩（见下文）反而更便宜。最后一行的拆分是集中度：漏钱是几场灾难，还是撒得很
薄？在这台机器上是后者——前五个会话只占溢价的约三分之一，这与诚实的结论相
吻合：无声的前缀漂移（`unknown 89`）重建的缓存比压缩（43 次）还多。漏钱的
地方很少在你以为的位置。

管道或 CI 输出保持纯文本（条形图和颜色以 TTY 为门控），`--json` 保持不变、
可供机器读取。

## Keep Warm

上面的一切都在*观察*。Keep Warm（保温）是可选的另一半，用于*预防*：它让缓
存在那些你打算回来的长时间等待中不至于过期。

```sh
warmline keep-warm on        # turn it on (once)
warmline keep-warm status    # is it on?
warmline keep-warm off       # turn it off
```

就这些。它是全局的（`~/.claude/CLAUDE.md` 中的一个块），适用于每个项目，并
在会话和安装器更新之间持续生效——设置一次就可以忘掉。（`./install.sh
--keep-warm` 在安装时执行同样的启用；`--uninstall` 会连同其他一切一起移除
它。）

```
$ warmline keep-warm status
keep-warm  ON
  scope    global -- applies to every project  (block in /Users/mb/.claude/CLAUDE.md)
  policy   intact
```

`status` 从不信任状态文件——它每次都读取你真实的 CLAUDE.md。手工删掉这个
块，它就报告 OFF；留下半个块，它就报告 INCONSISTENT 并附上修复方法，而不是
一个虚假的 ON。对脚本而言，退出码就是答案：`0` 开、`1` 关、`2` 不一致。

**它是什么：**一个简短的、以标记分隔的指令块（[`keep-warm.md`](keep-warm.md)），
你的 agent 在活跃会话期间遵循它。当 agent 启动的后台工作预计超过约 45 分
钟、且上下文可观时，它会安排一次约 50 分钟后的唤醒；醒来时若工作仍在进行就
重新安排，否则正常继续——结果就落在热缓存上。每次 ping 的成本约为你上下文的
0.1×（计入缓存读取额度），而冷重写约为 2×，因此只要你会回来，它对长达约
10–12 小时的空闲时段都是划算的。

**它不是什么：**

- **不是守护进程。** 没有后台进程、没有 cron、在运行中的 Claude Code 会话
  之外没有任何请求。Claude Code 不在运行时，什么也不会运行。
- **不是永远开启。** 当本地后台任务已经在进行时它会刻意*跳过*（它们的通知
  免费保持缓存温热——下文已实测），也会跳过小上下文——那种情况下变冷的重建
  成本本来就低。
- **不会在等待结束后继续存在。** 工作一恢复，唤醒就会被删除；并且单次等待
  在约 12 次重新安排（约 10 小时）后就会放弃——过了那个点，ping 的花费比它
  所防止的那次重建还多。

**它无法运作的时候：**唤醒无法在睡眠的主机上触发（macOS 上可用
`caffeinate -is` 让计划中的等待保持清醒）。某些 Claude Code 构建上
`ScheduleWakeup` 可能不存在或受门控——agent 会回退到定时的循环提示
（`/loop 50m <ping>`），或者这个块就处于惰性状态。而且它是指令、不是代码：
agent 可能没有遵循它。审计正是你验证它是否真的起效的方式。

**这符合 Anthropic 的条款吗？**我们做了调研，而不是想当然。keep-warm 依赖
的机制是有文档记载的产品行为：Anthropic 的
[提示词缓存文档](https://platform.claude.com/docs/en/build-with-claude/prompt-caching)
写明缓存"每次被使用时都会免费刷新"，并且对 API 使用明确建议定期发送预热请
求。一次保温 ping 是活跃会话内的一次普通计费请求：它消耗你自己的额度（通常
*少于*它所取代的那次冷重建），不绕过任何东西。真正要紧的边界在另一侧——
Anthropic 的每周限额正是为了遏制那些 7×24 小时连续运行 Claude Code 的账号。
这就是这个策略在设计上有边界的原因：它只在你真正打算回来的等待中 ping，至
多约每 50 分钟一次，在温热本来就免费时跳过，工作一恢复就停止，约 10 小时后
放弃，并且永远不是守护进程。不要放宽这些边界。仍有一个诚实的未知：在消费者
版 Claude Code 会话内的定时 ping 是否算作订阅计划所假定的「普通的个人使
用」，在我们能找到的任何资料里都没有提及——Anthropic 对这一具体用法的确切立
场是未知的。这一切并不意味着 Anthropic 为 keep-warm 背书——它意味着我们没有
找到它违反的规则，并且把它构建得远离 Anthropic 已出手处理过的那类行为。

## 冷着回来：`/compact`、`/clear`，还是都不做？

大上下文上的 `COLD(ttl?)` 是一个岔路口。缓存已经没了；无论你接下来做什么，
那些上下文都要再以昂贵的未缓存价格处理一次。唯一的问题是，这一次不可避免的
处理能给你换来什么：

- **你仍然需要对话历史 → `/compact`。** 压缩必须把整个对话读一遍才能总结。
  在热缓存上这次读取本来很便宜——但它同时会摧毁一个你已经付了 2× 建起来的
  缓存，这就是为什么在 `HOT` 时压缩是时机最糟糕的操作（除非你的上下文窗口
  已用尽、别无选择）。在冷缓存上，这次昂贵的处理反正在你下一条消息时就会发
  生——压缩只是把它引导为生成一份小小的总结，此后你缓存并携带的是几千 token
  而不是 100k+。`/compact` 恰恰在缓存已死时收益最大。
- **你的状态已写在对话之外 → `/clear`。** 如果你继续工作所需的东西存在于记
  忆文件、计划文档，或代码和 git 历史之中，`/clear` 连总结那一遍都省了——再
  也没有任何东西需要付费去读旧上下文。一个全新会话的前缀只是系统提示词、你
  的 CLAUDE.md 和记忆索引；文件只在变得相关时才会被重新读取，这几乎总是远
  便宜于对一个 100k+ 对话做一次总结。
- **小上下文 → 什么都不做。** 20k token 变冷的重建成本很低。这里的一切都是
  为 100k+ 的情况而存在的。

## 实测结果（不是建模推算）

以上每个说法都可以对照真实转录验证——Claude Code 会为每个 API 轮次记录
`cache_read_input_tokens` 和 `cache_creation_input_tokens`，`warmline-audit`
会给它们打分。以下来自一个真实的 13 小时编排会话（2026-08-18，约 300k 上下
文，带后台 CI 监视器的 merge-queue 值守）：

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
  消失，重写了全部 45,033 token。50 分钟时是热的、70 分钟时是冷的——1 小时
  TTL 是真实存在的，而保温 ping 间隔（约 50 分钟）安全地落在其内。
- 冷臂同时演示了 ping 为什么有效：**读取会刷新 TTL**。它的探针仍然发现共享
  的系统块是温热的，因为另一臂在 20 分钟前读过那个块。保温 ping 正是这样一
  次刷新，作用于你的整个前缀。
- 纵观这台机器的全部历史（8 周内 145 个会话），`warmline-audit --all` 按
  Sonnet 基础定价估算的可避免溢价总额为 **~$66**——并且把 43 次缓存重建归因
  于压缩，而 **89 次归因于无法解释的前缀漂移**。漏钱的地方很少在你以为的位置。
- 同一实验早前一次刻意"不干净"的运行揭示了一种更微妙的失败模式：无头
  `--resume` 会重新生成整个系统提示词，因此轮次之间的 git 状态漂移、MCP 服
  务器可用性变化或被编辑过的 CLAUDE.md 会让前缀悄然分叉——分叉点之后的一切
  都要按全价重新缓存。**前缀稳定性与 TTL 同样重要**：如果一个会话的前缀在
  轮次之间不断变动，任何保温 ping 都救不了它。

## 配置

| 环境变量 | 默认值 | 含义 |
|---|---|---|
| `WARMLINE_TTL_MIN` | `60` | 提示词缓存 TTL，单位为分钟（短 TTL 环境可设为 `5`） |
| `WARMLINE_STATE_DIR` | `~/.claude/warmline-state` | stamp/状态目录 |
| `WARMLINE_BIN_DIR` | `~/.local/bin` | 安装器放置 `warmline` 与 `warmline-audit` 命令的位置 |
| `WARMLINE_NO_COLOR` | 未设置 | 若设置（或设置了 `NO_COLOR`），输出纯文本、不含 ANSI 颜色 |
| `WARMLINE_FORCE_COLOR` | 未设置 | 若设置，即使在管道中审计输出也带颜色 |
| `WARMLINE_DEBUG` | 未设置 | 若设置，保留最后一次原始状态栏载荷以供检查 |

在 Claude Code 启动所在的环境中设置这些变量，或写进 `~/.claude/settings.json`
的 `env` 块。`WARMLINE_TTL_MIN` 同时被状态栏和 `warmline-audit` 遵循。

## 兼容性与更新

已针对 Claude Code **2.1.233**（写作时的当前版本）验证。状态栏的 JSON 字段
对照真实的 harness 载荷做过检查，`warmline-audit` 能解析这台机器上存在的所
有转录格式——Claude Code 版本 **2.1.181 到 2.1.233**、145 个会话、零格式错
误条目。已处理一个已知的格式怪癖：某些版本在约 28% 的 assistant 条目上省略
`requestId`，因此审计按 `message.id` 对 API 请求去重。

**更新：**安装器就是更新器。重新运行同一条 `curl | bash` 一行命令（或在拉
取过的检出中运行 `./install.sh`）——它能识别自己的状态栏，并把状态栏、
`warmline` 命令和审计器一起原地替换、无需 `--force`；每次运行都会备份你的
`settings.json`，而你的保温开/关选择会保持原样。
[CHANGELOG.md](CHANGELOG.md) 记录各个标签发布。

**Windows：**状态栏和审计器是纯标准库 Python，不关心操作系统；只有安装器和
测试套件是 bash。手动安装：

1. 把 `statusline.py` 复制到 `%USERPROFILE%\.claude\warmline-statusline.py`
   （并可选择把 `warmline-audit` 复制到任何方便的位置）
2. 在 `%USERPROFILE%\.claude\settings.json` 中设置
   `"statusLine": {"type": "command", "command": "python C:\\Users\\you\\.claude\\warmline-statusline.py"}`
3. 以 `python warmline-audit [args]` 运行审计器

`warmline` 命令同样是 bash，因此在 Windows 上请手工切换保温——在
`%USERPROFILE%\.claude\CLAUDE.md` 中添加或移除以标记分隔的块（其文本即
[`keep-warm.md`](keep-warm.md)）——或使用 WSL / Git Bash。ANSI 颜色在
Windows Terminal 中渲染正常。一个经过测试的 `install.ps1` 会是一份受欢迎的
贡献——依照本项目的理念，我们不发布自己无法测试的东西。

## 测试

```sh
./test.sh
```

对脚本回放具有代表性的状态栏载荷（热、冷重建、TTL 过期、稀疏、垃圾数据、
并发会话隔离、空闲重绘不重置时钟、新轮次覆盖 TTL 推断、过期倒计时、ANSI
颜色）；对 `warmline-audit` 回放一份合成转录（包括 `--price` 估算、每一种
冷原因归因，以及 TTY 与管道下的格式化）；对 `--all` 回放一个合成的多项目语
料库；并测试 `warmline` CLI 的保温状态转换（on→on、off→off、格式损坏的块
如实报告而不是虚假的 ON），验证无关的 CLAUDE.md 内容在每个操作后都完好保
留，并检查全新安装确实会落下 `warmline` 命令。同一套件在每次推送时都在 CI
中运行。

## 许可证

[MIT](LICENSE)

## 请我喝杯咖啡 ☕

BTC: `bc1qjsvtd3dd44llyu4rwz2ucl4kp9wd9kvpsj6tk5`
