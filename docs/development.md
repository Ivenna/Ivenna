# 参与开发

先按[运行指南](running.md)准备环境与配置。模块依赖、会话执行和存储关系见[架构说明](architecture.md)，开发约定见 [AGENTS.md](../AGENTS.md)。

## 仓库与构建

应用位于 `apps/`，可复用模块位于 `packages/`：

| 位置 | 职责 |
| --- | --- |
| [apps/server](../apps/server) | HTTP 接口、配置与服务生命周期 |
| [packages/agent](../packages/agent) | 会话执行、模型与记忆工具接入、程序状态存储 |
| [dev/memory](../dev/memory) | 记忆容器构建、SSH 入口与本地启动 |
| [compose.yaml](../compose.yaml) | 本地 PostgreSQL |

`apps/server` 依赖 `packages/agent`，根构建聚合应用。在仓库根目录运行：

```sh
zig build
```

构建产物安装到 `zig-out`。加载配置并启动所需容器后，从同一目录运行服务：

```sh
zig build serve
```

## 更新服务与记忆容器

服务代码、[schema.sql](../packages/agent/src/schema.sql) 和 [tools.json](../packages/agent/src/tools.json) 编译进本地应用。修改后停止服务，再运行 `zig build serve`，即可重新构建并启动；数据库结构的调整还需按下一节处理。

[memory.nu](../packages/agent/src/memory.nu) 是 agent 包拥有的远端记忆操作实现，由 [Containerfile](../dev/memory/Containerfile) 安装到记忆容器。修改该处理程序、容器构建文件、SSH 服务配置或容器内入口后，停止本地服务，重新创建记忆容器并启动服务：

```sh
dev/memory/start.sh down
dev/memory/start.sh up
zig build serve
```

`up` 在容器不存在时重新构建镜像，沿用同名记忆卷和已有 SSH 密钥。部署到其他远端工作区时，更新对应的处理程序与入口，部署位置见[使用远端记忆](running.md#使用远端记忆)。记忆工具的使用约定见[记忆房间](memory.md)。

## 调整程序数据结构

[schema.sql](../packages/agent/src/schema.sql) 定义当前程序会话表。服务启动时创建缺失的表，修改该文件不会更新已存在的表。

数据库结构需要随设计调整时，先停止本地服务，再清理旧对象或重建 `DATABASE_URL` 指向的程序库；重新启动服务时创建当前定义的表。程序库与记忆卷各自独立，重建程序库时保留记忆卷。
