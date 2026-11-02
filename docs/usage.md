# 使用会话

Ivenna 持续保存会话及其历史。创建会话后，后续输入沿用同一个会话 ID。以下示例使用 `http://127.0.0.1:5882`，连接其他服务时替换地址；本地启动步骤见[运行指南](running.md)。

## 创建会话

提交一个 JSON 对象，保存每次输入使用的默认字段；没有默认字段时可提交 `{}`：

```sh
curl http://127.0.0.1:5882/sessions \
  -H 'Content-Type: application/json' \
  -d '{"language":"zh-CN","timezone":"Asia/Shanghai"}'
```

成功时返回 `201` 和会话记录。记下其中的 `id`；初始 `state` 为 `{"waiting":{}}`，创建本身不会开始模型处理。

## 提交输入并查询结果

假设会话 ID 为 `1`，提交第一条输入：

```sh
curl http://127.0.0.1:5882/sessions/1/inputs \
  -H 'Content-Type: application/json' \
  -d '{"message":"请记住，我正在学习法语。"}'
```

响应 `202` 及 `{"id":1,"status":"accepted"}` 确认输入已接收并交由后台处理。随后查询会话，读取执行状态和已保存的历史：

```sh
curl http://127.0.0.1:5882/sessions/1
```

`state` 为 `pending` 或 `running` 分支时，处理仍在进行，可稍后再次查询。模型运行由服务管理，提交请求结束后仍会继续。

## 继续与恢复

后续输入仍提交到同一个 `/sessions/1/inputs`。会话正在运行时，新输入会排队，在当前轮次结束后接入；会话已进入 `waiting` 或 `failed` 时，新输入会调度它继续处理。

需要在没有新输入的情况下继续执行时，调用：

```sh
curl -X POST http://127.0.0.1:5882/sessions/1/resume
```

恢复接口接受 `waiting`、`failed` 或 `pending` 会话，继续使用已有历史。会话正在运行或不存在时返回 `409`。

## 输入字段

创建会话和提交输入的请求体都必须是 JSON 对象。创建时保存的字段作为默认值；每次提交输入时，顶层同名字段覆盖默认值，只对本次输入生效。嵌套对象和数组保持原结构，同名嵌套对象会整体覆盖。

例如，会话默认字段中的 `language` 为 `zh-CN`，某次输入提交 `{"language":"en","message":"Summarize what we know."}`，本次提供给模型的语言字段为 `en`，下次未指定时仍为 `zh-CN`。示例中的 `language` 和 `timezone` 都是普通字段，服务将它们提供给模型，没有针对这些名称的专门处理。

`session_id` 始终由服务设为当前会话 ID；合并后仍没有 `message` 字段时，补为空字符串。其他字段可按使用场景自行组织。

## 接口与会话记录

接口返回 JSON。`:id` 为创建会话后取得的 ID。

| 接口 | 请求体 | 成功响应 |
| --- | --- | --- |
| `POST /sessions` | 默认字段对象 | `201`，完整会话记录 |
| `POST /sessions/:id/inputs` | 本次输入对象 | `202`，`id` 和 `status: "accepted"` |
| `GET /sessions/:id` | 无 | `200`，完整会话记录 |
| `POST /sessions/:id/resume` | 无 | `202`，`id` 和 `status: "accepted"` |

`202` 响应中的 `status` 表示请求已接收；会话记录中的 `state` 表示执行状态。会话记录包含：

| 字段 | 含义 |
| --- | --- |
| `id` | 后续请求使用的会话 ID |
| `user_fields` | 创建会话时保存的默认字段 |
| `state` | 当前会话状态，只包含下表中的一个分支 |
| `messages` | 已保存的会话历史 |
| `pending_inputs` | 已接收、尚未接入历史的输入 |

| `state` 的值 | 含义 |
| --- | --- |
| `{"waiting":{}}` | 当前处理已暂停，可提交新输入或调用恢复接口继续 |
| `{"pending":{}}` | 已排队，等待后台执行 |
| `{"running":{}}` | 正在处理模型请求或工具操作 |
| `{"failed":"ModelHttpFailure"}` | 本轮执行失败，分支值是错误名称；示例值为 `ModelHttpFailure` |

请求体不是 JSON 对象时返回 `400`。查询或提交输入时，找不到会话返回 `404`。HTTP 错误回复使用 `{"error":"错误代码"}`。

## 持续使用时的行为

服务重启后，原先处于 `pending` 或 `running` 的会话会从已保存历史继续。中断前已经执行、尚未保存结果的记忆操作可能再次执行；检查点与恢复边界见[失败与恢复](architecture.md#失败与恢复)。

默认字段和历史按会话保存，[记忆空间](memory.md)由所有会话共享。长会话受模型上下文窗口限制，历史的保存与发送方式见[模型输入与历史](architecture.md#模型输入与历史)。
