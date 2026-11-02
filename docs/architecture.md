# 架构

Ivenna 通过 HTTP 接收输入，以持久会话执行模型与工具循环。程序状态保存在 PostgreSQL，自主记忆保存在经 SSH 访问的独立工作区；这两个存储边界分别服务于会话执行和记忆组织。

## 模块职责

`apps/server` 依赖 `packages/agent`，在 [main.zig](../apps/server/src/main.zig) 中组装共享 HTTP client、会话存储和执行引擎，并管理服务生命周期。

| 模块 | 职责 |
| --- | --- |
| [Api](../apps/server/src/api.zig) | 处理 HTTP 请求，调度会话任务并管理连接与任务的生命周期 |
| [Engine](../packages/agent/src/root.zig) | 创建会话，执行模型与工具循环，保存每轮结果 |
| [Provider](../packages/agent/src/provider.zig) | 调用模型接口，返回完整模型输出 |
| [Store](../packages/agent/src/store.zig) | 持久化会话、历史与输入收件箱，完成会话状态转换 |
| [Memory](../packages/agent/src/memory.zig) | 将结构化记忆请求交给远端处理器，返回记忆操作结果 |

HTTP 和并发使用 Zig 标准库，PostgreSQL 访问使用 `pg.zig`，输入的 YAML 序列化使用 `yaml-zig`。依赖版本由 [agent 包清单](../packages/agent/build.zig.zon) 固定；仓库布局和构建入口见[开发指南](development.md)。

## 程序状态与自主记忆

Store 通过数据库更新，将会话状态、历史和收件箱一起推进。因此 PostgreSQL 承担会话执行的持久化职责，结构由 [schema.sql](../packages/agent/src/schema.sql) 定义。应用中的会话状态包含 `waiting`、`pending`、`running` 和携带错误名称的 `failed`；数据库使用 `status` 与 `error_message` 编码，并由 schema 约束只有 `failed` 携带错误消息。HTTP 表示见[会话记录](usage.md#接口与会话记录)。

自主记忆由所有会话共享。模型使用 [tools.json](../packages/agent/src/tools.json) 定义的结构化工具选择记忆操作并提供参数，Memory 将请求编码为只含一个操作分支的 JSON，经 SSH 标准输入传递。例如读取请求为：

```json
{"read_memory":{"address":"语言/近况.md"}}
```

远端固定的 [memory.nu](../packages/agent/src/memory.nu) 处理请求，补齐省略的默认参数并限制操作位置。它使用 [fd](https://github.com/sharkdp/fd) 发现名称、[ripgrep](https://github.com/BurntSushi/ripgrep) 检索内容，以及 Nu 内置能力读写和整理条目。模型提供的内容与匹配表达作为数据处理，执行流程由处理器实现。

处理器返回互斥的 `result` 或 `error` 分支，分别以退出码 `0` 或 `1` 结束。Memory 核对回复与进程结果，将正常操作错误交回模型；传输异常的诊断保留在本地日志中，模型得到记忆不可用或修改结果不确定的错误。工具用法见[记忆房间](memory.md)，部署入口见[使用远端记忆](running.md#使用远端记忆)。

## 模型输入与历史

创建会话时，Engine 保存默认输入字段，并写入唯一的 system 消息：

> Je pense, donc je suis.

后续 HTTP 输入由 [input.zig](../packages/agent/src/input.zig) 与会话默认字段合并，补入会话 ID 后序列化为 YAML，作为模型的 user 消息。字段的合并规则见[输入字段](usage.md#输入字段)。

Provider 调用 DeepSeek 原生 `/responses` 接口。Engine 保留响应中的完整 `output`，包括 reasoning、消息和函数调用；每个工具结果以带有对应 `call_id` 的 `function_call_output` 追加到历史，供下一轮请求重放。

每轮循环使用独立 arena，保存检查点后释放本轮临时数据。持久化历史则持续增长，每次模型请求都会发送完整历史，当前尚未压缩或裁剪。

## 会话与检查点

会话 ID 在后续输入、等待和恢复中保持不变。创建会话只保存初始数据；提交输入或显式恢复才会调度执行。一次执行依次经过以下持久化边界：

1. 提交输入时，将消息追加到 `pending_inputs`。正在执行的会话保持 `running`，其余状态转为 `pending`。
2. worker 成功将 `pending` 改为 `running` 后才能执行，同时把收件箱并入历史并清空。重复调度同一会话不会启动多个执行循环。
3. 每轮模型与工具循环完成后，将完整模型输出和对应工具回复一起保存为检查点，同时并入期间收到的新输入并清空收件箱。

模型本轮没有调用工具，或调用了 `wait_for_input`，都会请求暂停。同一轮仍会处理完所有工具，后续工具不会撤销已提出的等待请求。只有请求暂停且收件箱为空时，会话才转为 `waiting`；否则继续执行。收件箱合并与暂停判断属于同一条数据库更新，使运行期间收到的输入能够继续接入会话。

## 服务任务与停止

提交输入的 HTTP 请求在保存输入并调度任务后返回 `202 Accepted`。会话任务持有服务级依赖和会话 ID，由服务管理，执行不依赖提交请求的连接是否仍然存在。

服务使用 `std.Io.Select` 等待监听任务或停止信号。监听任务拥有两个 `std.Io.Group`，分别管理 HTTP 连接和会话 worker。停止时先取消并等待连接任务，停止接收新工作；再取消并等待会话 worker，最后释放共享 HTTP client 与数据库连接池。

模型 HTTP 请求、数据库操作、SSH 子进程和执行循环使用同一个 `std.Io`，取消沿任务树传递。本地 SSH 进程也随会话任务收尾，远端操作是否已经完成仍取决于远端的实际执行结果。

## 失败与恢复

工具返回的 `error` 分支作为工具结果写入历史，由模型决定后续处理。模型请求或执行循环中的非取消错误会触发 `failed` 状态写入；若该写入也失败，服务记录日志。取消直接退出，不额外写入失败状态。

新输入或显式恢复可以让失败会话从已保存历史继续。服务启动时先将遗留的 `running` 转为 `pending`，再调度所有待执行会话。当前恢复方式要求一个程序状态库由单个服务进程管理。

会话检查点与远端记忆操作不在同一个事务中。若记忆已经改变，而服务在保存检查点前中断，恢复后可能重复执行该操作；连接中断或取消本地等待也不会撤销已完成的远端修改。对结果不确定的记忆修改，应先检查当前内容，再决定后续操作。
