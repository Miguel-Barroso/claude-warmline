# claude-warmline

[English](README.md) | [日本語](README.ja.md) | [繁體中文](README.zh-TW.md) | **简体中文**

[![tests](https://github.com/Miguel-Barroso/claude-warmline/actions/workflows/test.yml/badge.svg)](https://github.com/Miguel-Barroso/claude-warmline/actions/workflows/test.yml)
[![version](https://img.shields.io/github/v/tag/Miguel-Barroso/claude-warmline?label=version)](https://github.com/Miguel-Barroso/claude-warmline/tags)
[![license](https://img.shields.io/github/license/Miguel-Barroso/claude-warmline)](LICENSE)

**看见 Claude Code 何时在悄悄重新处理你的整个对话——并阻止其中可以避免的部分。**

为 Claude Code 隐藏的上下文/缓存经济提供轻量级可观测性：一条状态栏、一个审计工具，
以及一份可选的保温策略。除了 `python3` 和 `bash` 之外没有任何依赖；不向外发送任何
数据——一切都读自 Claude Code 早已记录在你机器上的数据。

![状态栏的三种状态：绿色 cache HOT 配 keep-warm on、黄色 cache COLD(rebuilt)、红色 cache COLD(ttl?) 配 keep-warm off](docs/statusline.svg)

## 30 秒版本

Claude 在消息之间不会记住任何东西。你每按一次回车，Claude Code 就把*整个*对话重新
发送一遍——系统提示、工具、它读过的每个文件、每一条回复。在长会话里，这轻易就是
每轮 10 万以上的输入 token。

让这件事仍然负担得起的，是服务端的**提示缓存**。可以把它想成 Claude 已经为你的对话
搭好的工作台：只要工作台还在，每条新消息就以大约正常输入价格的 **0.1 倍**去*读取*
它。搭建成本约为 **2 倍**——付一次，然后摊到之后的每一轮。

问题在于：这个工作台会在**大约一小时无操作后**被悄悄拆掉；而只要对话开头被改写，
它也会立刻消失（`/compact` 必然触发整体重建）。午饭后回到一个大会话，你的下一条
消息就要以 2 倍价格重付全部——偏偏在你最想要结果的时刻。

Claude Code 完全不会展示这些。warmline 把它变得可见——并帮你避免可以避免的部分。

## 快速开始

```sh
curl -fsSL https://raw.githubusercontent.com/Miguel-Barroso/claude-warmline/main/install.sh | bash

warmline status              # 当前安装并启用了什么
warmline keep-warm on        # 可选：预防可避免的冷启动
```

然后照常使用 Claude Code——状态栏会实时显示缓存状态。想知道某个会话（或全部会话）
实际花了多少：

```sh
warmline-audit               # 本会话，逐轮查看
warmline-audit --all         # 所有会话，按漏钱多少排序
```

[安装细节、参数、更新、Windows →](docs/INSTALL.md)

## 如何读这一行

```
Fable 5 | claude-warmline | ctx 43% (168k) | cache HOT | gap 12m | keep-warm on
```

| 字段 | 含义 |
|---|---|
| `ctx 43% (168k)` | 上下文窗口占用率，以及对话中的输入 token 数 |
| `cache HOT` | 上一个请求从提示缓存读取（绿色） |
| `cache HOT (cold in 9m)` | 仍然是热的，但距 TTL 不足 15 分钟——现在行动，否则支付重建（黄色） |
| `cache COLD(rebuilt)` | 上一个请求发现前缀已冷，并重新缓存了它（黄色） |
| `cache COLD(ttl?)` | *推断*：安静时间超过 TTL，因此缓存已过期（红色） |
| `gap 12m` | 距本会话上一次 API 轮次的分钟数；空闲重绘不会重置它 |
| `keep-warm on` | [保温策略](#keep-warm)是否已安装——`off` 为暗色，块损坏时显示 `?` |

两点诚实的说明：Claude Code 传给状态栏的用量数字属于*上一个*请求，所以
`HOT`/`COLD(rebuilt)` 会滞后一轮；而 `COLD(ttl?)` 是基于时间的推断——所以才有那个
`?`。warmline 保证的是空闲计时能跨越重绘存活，因此你回来后的第一次重绘就已经显示
`COLD(ttl?)`——在你花掉任何东西之前。

[全部字段、颜色、gap 机制、故障排查 →](docs/STATUSLINE.md)（英文）

## 冷着回来时：`/compact`、`/clear`，还是什么都不做？

大上下文上的 `COLD(ttl?)` 是一个岔路口。缓存已经没了；无论你接下来做什么，那段
上下文都会再以昂贵的未缓存价格处理一次。唯一的问题是：这一次无法避免的处理买到了
什么？

- **你仍然需要对话历史 → `/compact`。** 压缩必须把整个对话读一遍才能生成摘要。缓存
  还热时这次读取很便宜——但它同时会摧毁你已支付 2 倍代价建立的缓存，所以在 `HOT`
  时压缩是时机最差的一步（除非上下文窗口已满、别无选择）。缓存已冷时，那次昂贵的
  处理反正也会发生在你的下一条消息上——压缩只是把它改用于产出一份小摘要，从此你
  缓存并携带的是几千个 token，而不是 10 万以上。`/compact` 收益最大的时刻，恰恰是
  缓存已经死掉的时候。
- **你的状态写在对话之外 → `/clear`。** 如果你需要的东西在记忆文件、计划文档、代码
  和 git 历史里，`/clear` 连摘要那一次都省掉——没人再花钱去读旧上下文。新会话的前缀
  只有系统提示、你的 CLAUDE.md 和记忆索引；文件只在真正需要时才重读，这几乎总是
  远比对 10 万以上 token 的对话做一次摘要更便宜。
- **上下文很小 → 什么都不做。** 2 万 token 冷掉了重建也很便宜。这里的一切都是为了
  10 万以上的情况而存在。

## 钱漏到哪里去了

`warmline-audit` 会给会话中每一个被记录的 API 请求评分——没有滞后、不靠推断。
`--all` 则把机器上所有会话按**可避免的冷 token**排序：也就是在每个会话无法避免的
首次写入之后，所有在冷状态下重新缓存的量。以下是某台机器 8 周历史的真实输出：

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

每个冷轮次都会在记录能证明的范围内附上原因——`/compact`、`auto-compact`、
`model change`、`inactivity`——证明不了的就诚实标为 `unknown`（实际多半是前缀漂移：
被编辑的 CLAUDE.md、变化的 git 状态、MCP 可用性）。注意这里的含义：无声的漂移重建的
缓存比压缩还多。漏钱之处，往往不在你以为的地方。

这个金额是从你自己记录中的 token 数推算出来的，绝不是账单数据。

[完整讲解、判定、原因、`--all`、`--json` →](docs/AUDIT.md)（英文）

## Keep Warm

以上全是*观测*。Keep Warm 是可选的*预防*另一半：放在 `~/.claude/CLAUDE.md` 里的
一段简短指令，告诉智能体在漫长而安静的等待期间大约每 50 分钟 ping 一次，好让结果
回来时缓存仍是热的。

```sh
warmline keep-warm on        # 全局；跨会话与更新持续有效
warmline keep-warm status    # ON / OFF / INCONSISTENT（退出码 0 / 1 / 2）
warmline keep-warm off
```

它**不是守护进程**——没有 cron、没有常驻进程，也不会在运行中的 Claude Code 会话
之外发出任何请求。当后台任务已经免费让缓存保持热度时它会跳过，上下文很小时也跳过，
工作一恢复就停止，并在大约 10 小时后放弃。一次 ping 的成本约为上下文的 0.1 倍；
它所预防的重建约为 2 倍。

[它是什么、不是什么、何时无法运作、条款讨论 →](docs/KEEP-WARM.md)（英文）

## 在哪些地方有效

| 前端 | 状态栏 | `warmline-audit` | keep-warm |
|---|---|---|---|
| 终端 CLI | ✅ | ✅ | ✅ |
| 桌面应用（本地 Code 标签页） | ❌ | ✅ | ✅ |
| VS Code / JetBrains 面板 | ❌ | ✅ | ✅ |
| 云端 / Cowork 会话 | ❌ | ❌ | — |

图形前端不会渲染自定义状态栏（[已提出的需求](https://github.com/anthropics/claude-code/issues/41456)），
但它们运行的是同一个引擎、共享同一个 `~/.claude`、写出同样的记录文件，因此审计工具
和保温策略在那里照常工作。如果你在桌面应用里也想要这条仪表，就在集成终端中运行
`claude`。

[完整对照表与验证方式 →](docs/SURFACES.md)（英文）

## 实测，而非建模

- **闲置 50 分钟：热的。70 分钟：冷的。** 在无干扰环境下的双臂探测中，50 分钟后的
  探针读回了完整的 71,312 token 前缀，70 分钟后则重写了 45,033 个 token。一小时的
  TTL 是真的，而且读取会刷新它——这正是 ping 有效的原因。
- **后台工作会免费保持缓存热度。** 每约 9 分钟一次的任务通知，让 30 万 token 的
  上下文连续四小时保持 HOT，每次唤醒只写入约 400 个 token。所以 keep-warm 会跳过
  这种情况。
- **合上盖子后没有任何唤醒能存活。** 在一段 13 小时、260 轮的会话中，唯一一次 TTL
  过期发生在机器休眠的 6 小时夜间静默之后。
- **前缀稳定性与 TTL 同样重要。** 漂移的系统提示（被编辑的 CLAUDE.md、变化的 git
  状态、MCP 可用性）会让分歧点之后的一切重新缓存，任何 ping 都救不了。

[数据、方法、如何复现 →](docs/MEASUREMENTS.md)（英文）

## 文档

详细文档仅提供英文版。

| | |
|---|---|
| [Statusline](docs/STATUSLINE.md) | 全部字段、颜色、gap 机制、故障排查 |
| [Audit](docs/AUDIT.md) | 判定、原因归因、`--all`、"avoidable" 的定义 |
| [Keep Warm](docs/KEEP-WARM.md) | 策略、其限制与条款讨论 |
| [Where it works](docs/SURFACES.md) | 终端、桌面、IDE、SSH、云端 |
| [Install](docs/INSTALL.md) | 安装、更新、卸载、配置、Windows、测试 |
| [Measurements](docs/MEASUREMENTS.md) | 支撑每一项主张的实测数据 |
| [Changelog](CHANGELOG.md) | 带标签的版本 |

## 许可证

[MIT](LICENSE)

## 请我喝杯咖啡 ☕

BTC: `bc1qjsvtd3dd44llyu4rwz2ucl4kp9wd9kvpsj6tk5`
