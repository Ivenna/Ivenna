# 参与开发

运行环境与配置见[运行指南](running.md)，模块依赖、会话执行与存储关系见[架构说明](architecture.md)。

## 仓库与构建

这是一个 monorepo，应用位于 `apps/`，可复用模块位于 `packages/`：

| 位置 | 职责 |
| --- | --- |
| [apps/server](../apps/server) | HTTP 接口、配置与服务生命周期 |
| [packages/agent](../packages/agent) | 会话循环、模型接入、工具与持久化 |
| [dev/postgres](../dev/postgres) | 本地记忆库与账号的初始化 |
| [compose.yaml](../compose.yaml) | 本地开发所需的 PostgreSQL |

根构建聚合应用。应用拥有各自的构建入口和依赖，`apps/server` 依赖 `packages/agent`。

在仓库根目录构建并安装应用到 `zig-out`：

```sh
zig build
```

加载运行配置并启动 PostgreSQL 后，可从根目录启动服务：

```sh
zig build serve
```

也可以使用应用自己的构建入口：

```sh
(cd apps/server && zig build)
(cd apps/server && zig build run)
```

## 调整程序数据结构

项目仍在探索，数据结构、数据库表、接口和模块边界按当前设计直接调整。开发工作约定见根目录的 [AGENTS.md](../AGENTS.md)。

[schema.sql](../packages/agent/src/schema.sql) 是程序会话表的当前定义。服务启动时初始化缺失的表，已有表的结构不会随文件修改自动更新。开发阶段不维护旧结构兼容或迁移，结构变化时按需重建程序库。

重建前先停止本地服务，目标为 `DATABASE_URL` 指向的程序库；随后重新启动服务以初始化当前 schema。程序库与记忆库共用 PostgreSQL 数据卷，重建程序库时保留这个卷和 Ivenna 的记忆库。

SQL 定义和 [tools.json](../packages/agent/src/tools.json) 都通过 `@embedFile` 编译进服务，修改后需要重新构建。Ivenna 记忆库中的表由它自行组织，程序不预定义记忆表。
