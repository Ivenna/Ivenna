# 运行 Ivenna

以下步骤从仓库根目录启动本地 HTTP 服务。默认开发环境中的 PostgreSQL 和记忆工作区运行在容器中，Ivenna 服务在本地运行。

## 准备环境与配置

需要安装 [`.zig-version`](../.zig-version) 指定的 Zig、OpenSSH 客户端，准备 DeepSeek API 密钥，以及支持 Compose 的容器环境。

通过 `CONTAINER_ENGINE` 指定本机容器引擎入口。其值为单个可执行文件路径或命令名，该入口需支持容器管理命令和 `compose` 子命令。本机所需的额外参数或环境设置可放在包装脚本中。

在仓库根目录复制配置：

```sh
cp -n .env.example .env
```

编辑 `.env`，填写 `LLM_API_KEY` 和 `CONTAINER_ENGINE`。模板中的 `MEMORY_SSH_CONFIG` 用于连接下面创建的本地记忆容器，其余配置沿用默认值。`.env` 和启动时生成的本地文件均已被 Git 忽略。

## 启动服务

在同一终端加载配置，再启动 PostgreSQL、记忆容器和服务：

```sh
set -a
. ./.env
set +a
"$CONTAINER_ENGINE" compose up -d --wait db
dev/memory/start.sh up
zig build serve
```

[记忆启动脚本](../dev/memory/start.sh)首次运行时构建镜像、创建记忆卷和 SSH 密钥，将连接配置写入 `.ivenna/dev-memory/`，并等待记忆工具可用。后续运行会使用已有容器、卷和密钥。本地记忆入口为 `ivenna-memory`，默认监听 `127.0.0.1:2222`。

服务默认监听 `http://127.0.0.1:5882`，通过 DeepSeek [Responses API](https://api-docs.deepseek.com/guides/responses_api/) 调用 `deepseek-flash`。保持此终端中的服务运行，在另一个终端按[使用指南](usage.md)提交输入。同一个程序数据库由单个服务进程使用。

## 调整配置

服务从进程环境读取配置。需要改变行为时，在 `.env` 中增加对应覆盖；修改后停止服务，在新终端重新执行启动步骤。

| 调整内容 | 配置项 |
| --- | --- |
| HTTP 监听地址与端口 | `HOST`、`PORT` |
| 模型 API 地址与模型 | `LLM_BASE_URL`、`LLM_MODEL` |
| 程序会话数据库连接 | `DATABASE_URL` |
| 记忆工作区的 SSH 连接 | `MEMORY_SSH_TARGET`、`MEMORY_SSH_CONFIG`，见[使用远端记忆](#使用远端记忆) |

本地模板中的 SSH 配置路径相对于服务进程的工作目录。本文统一从仓库根目录启动；从其他目录启动时，将 `MEMORY_SSH_CONFIG` 改为绝对路径。

本地 PostgreSQL 的端口和首次初始化密码由 `POSTGRES_PORT`、`POSTGRES_PASSWORD` 覆盖。更改端口时，同步修改 `DATABASE_URL`；更改已有数据库的登录密码时，同步修改数据库角色和连接 URL。容器环境中的密码只用于首次初始化，参见 [PostgreSQL 镜像说明](https://github.com/docker-library/docs/tree/master/postgres#environment-variables)。

本地记忆容器可通过 `MEMORY_SSH_PORT` 调整端口，通过 `MEMORY_CONTAINER_NAME`、`MEMORY_VOLUME_NAME`、`MEMORY_IMAGE` 选择容器、记忆卷和镜像名称。这些配置在创建容器时生效：先使用原配置运行 `dev/memory/start.sh down`，修改并在新终端加载配置后，再运行 `up`。更新镜像内容的方法见[更新服务与记忆容器](development.md#更新服务与记忆容器)。

## 使用远端记忆

连接已有远端工作区时，先配置好 SSH，再按启动流程运行 PostgreSQL 和服务，省去本地记忆容器的启动步骤。

应用默认使用 `ivenna-memory` 这个 SSH 目标，使用其他目标时设置 `MEMORY_SSH_TARGET`。使用 OpenSSH 常规配置时，从 `.env` 中移除模板提供的 `MEMORY_SSH_CONFIG`；使用专用配置文件时，将其设为文件路径。用户、主机名、密钥、连接超时和主机密钥验证由 SSH 配置管理。

远端需要安装 Nushell、ripgrep 和 fd，并部署两个固定文件：

- 将 [memory.nu](../packages/agent/src/memory.nu) 安装到 `/usr/local/lib/ivenna/memory.nu`。
- 按 [memory-shell.sh](../dev/memory/memory-shell.sh) 提供 `/usr/local/bin/memory-shell` 入口，进入 `/memory` 后运行该处理程序。SSH 账号需能读写这个工作区。

应用通过 SSH 调用固定入口。容器内的安装方式与 SSH 服务配置分别见 [Containerfile](../dev/memory/Containerfile) 和 [sshd_config](../dev/memory/sshd_config)，可作为远端部署参考。

## 停止与再次运行

在服务终端按 `Ctrl+C` 停止 Ivenna。PostgreSQL 和记忆容器仍在运行时，再执行 `zig build serve` 即可继续使用已保存的会话与记忆。

需要一并停止本地容器时，运行：

```sh
dev/memory/start.sh down
"$CONTAINER_ENGINE" compose down
```

这些命令保留数据卷和 SSH 密钥。下次使用时，重新执行[启动服务](#启动服务)的步骤。运行 `dev/memory/start.sh status` 可查看本地记忆容器状态。
