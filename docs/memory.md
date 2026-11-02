# 记忆房间

记忆房间是 Ivenna 跨会话共享的持久记忆空间。模型通过浏览、寻找、回忆、记录和修订等工具组织内容，每次调用只需选择工具并提供参数。房间层级、条目名称、文本格式和相互引用由 Ivenna 自行形成。

本地启动见[运行指南](running.md)，连接其他记忆工作区见[使用远端记忆](running.md#使用远端记忆)。执行协议与模块边界见[架构说明](architecture.md#程序状态与自主记忆)。

## 位置与组织

| 概念 | 含义 |
| --- | --- |
| 记忆房间 | 容纳相关条目和子房间的空间 |
| 记忆条目 | 保存在某个位置的文本，内容与格式由 Ivenna 决定 |
| 位置 | 相对于记忆空间入口的路径，例如 `语言/近况.md`；`.` 表示入口 |
| 线索 | 用于寻找名称或检索内容的文本、通配模式或正则表达式 |

所有位置都相对于入口。`room` 仅限定浏览或检索的范围，每次调用独立定位；返回的位置也始终相对于入口。房间或条目移动后，位置随之改变，需要保留的引用由 Ivenna 一同整理。

## 工具与参数

[tools.json](../packages/agent/src/tools.json) 定义模型可用的工具及参数。下表列出各工具的必需参数；可选参数省略时采用默认行为。

| 工具 | 必需参数 | 用途 |
| --- | --- | --- |
| `browse_memory_room` | 无 | 浏览房间中的条目和子房间 |
| `find_memory` | `query` | 按名称寻找条目和房间 |
| `recall_memory` | `clue` | 按内容回忆相关条目 |
| `read_memory` | `address` | 阅读指定条目的完整内容 |
| `remember` | `address`、`content` | 新建条目、追加或替换内容 |
| `revise_memory` | `address`、`old_text`、`new_text` | 修订条目中的匹配内容 |
| `create_memory_room` | `address` | 创建房间，按需建立父级 |
| `move_memory` | `address`、`destination` | 移动或重命名条目及房间 |
| `forget_memory` | `address` | 删除条目或房间 |

浏览、寻找和回忆可通过 `room` 指定范围，省略时从入口开始。`find_memory` 和 `recall_memory` 都会检索子房间。

名称检索的 `match_mode` 支持 `literal`、`glob` 和 `regex`，内容检索支持 `literal` 和 `regex`。默认使用字面文本，其中名称检索匹配名称中的片段。两种检索默认忽略大小写，设置 `case_sensitive: true` 可区分大小写。

记录内容时，`mode` 默认为 `create`，位置已存在时报错；`append` 追加内容，`replace` 替换完整内容。新建条目前，先按需要创建所在的记忆房间。

修订默认按字面文本区分大小写，只替换第一处匹配。`replace_all: true` 替换全部匹配；`match_mode: "regex"` 启用正则表达式，替换内容可使用 `${1}`、`${name}` 等捕获组引用。正则本身也可使用内联标志。

移动时，`destination` 可以是一个新位置，也可以是已有房间；移入已有房间时保留原名称，实际目标已存在时报错。删除默认适用于条目或空房间；`recursive: true` 可删除房间及其全部内容。入口位置始终保留。

## 操作示例

调用 `create_memory_room`，建立一个房间：

```json
{"address":"语言"}
```

调用 `remember`，留下一个条目：

```json
{"address":"语言/近况.md","content":"法语：每周练习两次。日语：每周练习一次。"}
```

调用 `recall_memory`，在指定房间中回忆相关内容：

```json
{"clue":"法语","room":"语言"}
```

调用 `find_memory`，按名称模式寻找条目：

```json
{"query":"*.md","room":"语言","match_mode":"glob"}
```

调用 `revise_memory`，调整一处内容：

```json
{"address":"语言/近况.md","old_text":"每周练习两次","new_text":"每周练习三次"}
```

也可以用正则表达式同时修订多处，例如将两个语种名称改为学习项目名称：

```json
{"address":"语言/近况.md","old_text":"(法语|日语)：","new_text":"${1}学习：","replace_all":true,"match_mode":"regex"}
```

## 理解结果与错误

每次回复只有 `result` 或 `error` 中的一种。成功时，`result` 包含本次操作的结果，例如记录完成后返回位置：

```json
{"result":{"address":"语言/近况.md"}}
```

| 操作 | `result` 中的内容 |
| --- | --- |
| 浏览 | `room` 和 `entries`；每项有 `address`、`name`、`kind` |
| 按名称寻找 | `room`、`query` 和 `matches`；每项有 `address`、`name`、`kind` |
| 按内容回忆 | `room`、`clue` 和 `matches`；每项有 `address`、`line`、`text` |
| 阅读 | `address` 和 `content` |
| 修订 | `address` 和 `revision` |
| 记录、创建房间、移动、删除 | `address`；移动返回实际的新位置 |

`kind` 的 `room` 表示记忆房间，`memory` 表示记忆条目。检索没有匹配时，`matches` 为空列表；内容匹配的 `line` 从 1 开始。修订结果的 `revision` 有三个值：

| 值 | 含义 |
| --- | --- |
| `no_match` | 未找到匹配内容 |
| `unchanged` | 找到匹配，但内容保持不变 |
| `revised` | 内容已修订 |

失败时，`error` 提供 `code` 和 `message`，描述本次操作遇到的问题。`memory_unavailable` 表示只读操作未取得完整回复；`memory_change_uncertain` 表示修改是否完成尚未确认。遇到后者，先读取相关条目；涉及创建、移动或删除时，浏览原位置与目标位置，再决定是否重试。

会话恢复可能重复执行尚未记入检查点的操作，相关执行边界见[失败与恢复](architecture.md#失败与恢复)。
