# 运行 Ivenna

以下步骤从源码构建并启动本地 HTTP 服务。

## 准备环境

需要安装 [`.zig-version`](../.zig-version) 指定的 Zig、Docker 和 Compose，并准备 DeepSeek API 密钥。PostgreSQL 由容器运行，Ivenna 服务在本地运行。

在仓库根目录复制配置：

```sh
cp -n .env.example .env
```

编辑 `.env`，填写 `LLM_API_KEY`；该文件已被 Git 忽略。默认通过 DeepSeek 原生 [Responses API](https://api-docs.deepseek.com/guides/responses_api/) 调用 `deepseek-flash`，配置模板见 [.env.example](../.env.example)。

## 启动服务

在仓库根目录的同一终端加载配置，再启动 PostgreSQL 和 Ivenna：

```sh
set -a
. ./.env
set +a
docker compose up -d --wait db
docker compose exec -T db /docker-entrypoint-initdb.d/10-memory.sh
zig build serve
```

[初始化脚本](../dev/postgres/init-memory.sh)只创建缺失的记忆库和账号，可重复执行；已有数据和账号密码保持不变。

服务默认监听 `http://127.0.0.1:5882`。保持这个终端中的服务运行，在另一个终端按[使用指南](usage.md)提交输入。当前同一程序数据库由单个服务进程管理。

## 配置

服务从进程环境读取配置。修改 `.env` 或打开新终端后，先重新加载配置，再启动服务。

| 配置项 | 用途 |
| --- | --- |
| `LLM_API_KEY` | DeepSeek API 密钥，启动前填写 |
| `LLM_BASE_URL`、`LLM_MODEL` | 模型 API 地址和模型名称 |
| `HOST`、`PORT` | HTTP 服务监听地址和端口 |
| `DATABASE_URL` | 程序会话状态与历史的数据库连接，默认库为 `ivenna` |
| `MEMORY_DATABASE_URL` | Ivenna 自主管理的记忆库连接，默认库为 `ivenna_memory` |
| `POSTGRES_PORT` | Compose 暴露的 PostgreSQL 端口 |
| `POSTGRES_PASSWORD` | PostgreSQL 首次初始化时设置的程序账号密码 |
| `MEMORY_DATABASE_PASSWORD` | 初始化脚本创建记忆库账号时设置的密码 |

两个数据库共用本地 PostgreSQL 实例。记忆库由专属账号拥有，Ivenna 可以修改或删除其中的表与数据；会话状态保存在程序库中。

变更 PostgreSQL 端口时，同步更新两个连接 URL。变更登录密码时，需要同步数据库角色和对应连接 URL；修改 `.env` 或重跑初始化脚本不会更改已有账号密码，参见 [PostgreSQL 镜像说明](https://github.com/docker-library/docs/tree/master/postgres#environment-variables)。

## 停止与再次运行

在服务终端按 `Ctrl+C` 停止 Ivenna。再次加载配置并运行 `zig build serve`，会继续使用已经保存的会话与记忆；会话恢复行为见[使用指南](usage.md)。

停止 PostgreSQL：

```sh
docker compose down
```

该命令保留数据库卷，会话历史与记忆可在下次启动时继续使用。
