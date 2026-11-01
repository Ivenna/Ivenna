# 架构

Ivenna 由 HTTP 服务、会话执行引擎及两个 PostgreSQL 数据库组成。服务管理输入和任务生命周期，引擎执行模型与工具循环，数据库分别保存程序状态和自主记忆。

## 模块职责

`apps/server` 依赖 `packages/agent`。服务在 [main.zig](../apps/server/src/main.zig) 中组装共享 HTTP client、会话存储和执行引擎；[api.zig](../apps/server/src/api.zig) 处理 HTTP 请求，agent 包的 [root.zig](../packages/agent/src/root.zig) 执行会话。仓库位置和构建入口见[开发指南](development.md)。

HTTP 和并发使用 Zig 标准库，PostgreSQL 访问使用 `pg.zig`，YAML 序列化使用 `yaml-zig`；依赖版本由 [agent 的包清单](../packages/agent/build.zig.zon) 固定。会话表由 [schema.sql](../packages/agent/src/schema.sql) 定义，模型可用工具由 [tools.json](../packages/agent/src/tools.json) 定义。

## 服务拥有执行任务

提交输入的请求负责保存输入并调度会话，随后返回 `202 Accepted`。会话任务持有服务级依赖和会话 ID，由服务管理生命周期，独立于 HTTP 连接。

服务使用 `std.Io.Select` 等待监听任务或停止信号。监听任务拥有两个 `std.Io.Group`：一个管理 HTTP 连接，一个管理会话 worker。停止时先取消并等待连接任务结束，使请求无法再提交新任务；再取消并等待会话 worker，最后释放共享 HTTP client 和数据库连接池。

模型 HTTP 请求、数据库操作和执行循环使用同一个 `std.Io`，取消沿任务树传递。

每轮模型与工具循环使用独立 arena，保存检查点后释放本轮临时数据。持久化历史持续增长，每次模型请求都会发送完整历史，尚未实现压缩或裁剪。

## 会话与检查点

会话是持久化的执行单位。创建时保存用户字段和唯一的 system 消息，状态为 `waiting`；输入、等待和恢复都沿用同一个会话及其历史。各状态的调用方式见[使用会话](usage.md)。

[Store](../packages/agent/src/store.zig) 将几个边界放在单条数据库更新中完成：

- 提交输入时，先追加到 `pending_inputs` 收件箱。正在运行的会话保持 `running`，其余状态转为 `pending`。
- worker 只有成功将 `pending` 改为 `running` 才能执行，同时把收件箱并入历史并清空；同一会话的重复调度不会启动多个执行循环。
- 每轮完成后，把完整模型输出及对应工具回复一起保存为检查点，同时并入期间到达的新输入并清空收件箱。只有本轮请求暂停且收件箱为空时，才转为 `waiting`；否则继续运行。

模型没有调用工具，或调用 `wait_for_input`，都会请求在本轮结束后暂停。暂停判断与收件箱合并属于同一次更新，输入不会因旧历史覆盖而丢失，也不会留在已休眠的 worker 后面。

普通执行错误将会话记为 `failed`，新输入或显式恢复可从已保存历史继续。取消直接退出，不额外执行失败状态写入；启动时把遗留的 `running` 转回 `pending`，再调度执行。当前恢复方式以一个程序状态库由单个服务进程使用为前提。

检查点覆盖一轮模型输出和工具回复，不覆盖外部工具的事务。若 SQL 已产生效果，而进程在保存检查点前中断，恢复后可能重复执行该操作。

## 模型输入与历史

[Provider](../packages/agent/src/provider.zig) 调用 DeepSeek 原生 `/responses` 接口。程序保存响应中的完整 `output` 项，包括 reasoning、消息和函数调用；工具结果以带有对应 `call_id` 的 `function_call_output` 追加到历史，下一轮一并重放。

system prompt 仅有这一句，由创建会话的代码写入：

> Je pense, donc je suis.

HTTP 输入为 JSON 对象。[输入模块](../packages/agent/src/input.zig) 按[输入字段约定](usage.md#输入字段)合并默认值与本次输入，序列化为 YAML，作为模型的 user 消息内容。

## 程序状态与自主记忆

程序通过两个连接配置区分存储职责：

| 配置 | 用途 |
| --- | --- |
| `DATABASE_URL` | 程序管理的会话状态、历史和收件箱，结构由 `schema.sql` 定义。 |
| `MEMORY_DATABASE_URL` | `database` 工具访问的自主数据库，跨会话共享，由 Ivenna 自行组织表和数据。 |

本地记忆库及其所有者账号由[初始化脚本](../dev/postgres/init-memory.sh)创建。程序不预定义记忆表，Ivenna 可以在该库中创建、修改、查询和删除结构及数据。程序会话表的维护见[开发指南](development.md#调整程序数据结构)。

[database 工具实现](../packages/agent/src/database.zig) 接收一份 SQL 脚本，每次调用建立并关闭独立连接。需要共享连接状态或使用显式事务的语句，应放在同一次调用中；连接状态不会延续到下一次调用。

多条命令的结果按顺序放入 `results`，每项包含列名、行、命令标签和受影响行数。非空单元格返回 PostgreSQL 文本表示的字符串，SQL `NULL` 对应 JSON `null`；程序不将单元格转换为 JSON 数值或布尔值。

SQL 执行错误作为工具结果返回给模型，并保留此前完成的命令结果，供后续判断或修正；连接、传输及内存分配失败则沿执行错误路径处理，取消继续沿任务树传播。先前显式提交的改动可以在后续语句报错后保留，取消本地任务也不构成远端操作已经撤销的保证。当前未实现 `COPY` 流，遇到对应响应会返回工具错误并关闭连接。
