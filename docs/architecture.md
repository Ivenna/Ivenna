# Architecture

Ivenna receives input over HTTP and runs model requests and tool calls in persistent sessions. Application state is stored in PostgreSQL, while autonomous memory lives in a separate workspace accessed over SSH. The two stores separate session execution state from the memory Ivenna organizes for itself.

## Module responsibilities

`apps/server` depends on `packages/agent`. It assembles the shared HTTP client, session store, and execution engine in [main.zig](../apps/server/src/main.zig) and manages the service lifecycle.

| Module | Responsibility |
| --- | --- |
| [Api](../apps/server/src/api.zig) | Handle HTTP requests, schedule session tasks, and manage connection and task lifecycles |
| [Engine](../packages/agent/src/root.zig) | Create sessions, run model and tool loops, and save each turn's results |
| [Provider](../packages/agent/src/provider.zig) | Call the model API and return its complete output |
| [Store](../packages/agent/src/store.zig) | Persist sessions, history, and the input inbox, and apply session state transitions |
| [Memory](../packages/agent/src/memory.zig) | Send structured memory requests to the remote handler and return operation results |

HTTP and concurrency use the Zig standard library. PostgreSQL access uses `pg.zig`, and input serialization to YAML uses `yaml-zig`. Dependency versions are pinned in the [agent package manifest](../packages/agent/build.zig.zon). See the [development guide](development.md) for the repository layout and build commands.

## Application state and autonomous memory

Store updates session state, history, and the input inbox together in PostgreSQL, using the structure defined in [schema.sql](../packages/agent/src/schema.sql). A session can be `waiting`, `pending`, `running`, or `failed`; a `failed` state also carries an error name. The database stores these values in `status` and `error_message`, with a schema constraint allowing an error message only for `failed`. See [API and session records](usage.md#api-and-session-records) for the HTTP representation.

Autonomous memory is shared across all sessions. The model chooses memory operations and supplies arguments through the structured tools defined in [tools.json](../packages/agent/src/tools.json). Memory encodes each request as a JSON object containing a single operation and sends it to the SSH process's standard input. For example, a read request is:

```json
{"read_memory":{"address":"languages/progress.md"}}
```

The remote handler, [memory.nu](../packages/agent/src/memory.nu), runs at a fixed path, fills in default values for omitted arguments, and confines operations to the memory workspace. It uses [fd](https://github.com/sharkdp/fd) to find names, [ripgrep](https://github.com/BurntSushi/ripgrep) to search content, and Nushell built-ins to read, write, and organize entries. The handler runs predefined operations, treating content and match expressions supplied by the model as data.

The handler returns either a `result` branch with exit code `0` or an `error` branch with exit code `1`. Memory verifies that the response and exit code agree, then passes operation errors back to the model. Transport failures are logged locally; the model receives an error indicating that memory is unavailable or that the outcome of a change is uncertain. See [memory rooms](memory.md) for tool usage and [using remote memory](running.md#using-remote-memory) for deployment.

## Model input and history

When creating a session, Engine saves its default input fields and adds the sole system message:

> Je pense, donc je suis.

Subsequent HTTP inputs are merged with the session defaults by [input.zig](../packages/agent/src/input.zig). The session ID is added, and the result is serialized to YAML as a user message for the model. See [input fields](usage.md#input-fields) for the merge rules.

Provider calls DeepSeek's native `/responses` endpoint. Engine retains the response's complete `output`, including reasoning, messages, and function calls. Each tool result is appended to history as a `function_call_output` with the corresponding `call_id` so it can be replayed in the next request.

Each loop iteration uses its own arena and releases its temporary data after saving a checkpoint. Persisted history continues to grow, and every model request sends the full history. History is not currently compacted or trimmed.

## Sessions and checkpoints

The session ID stays the same across subsequent inputs, pauses, and resumes. Creating a session only saves its initial data; submitting input or explicitly resuming the session schedules execution. State is saved at three points:

1. Submitting input appends the message to `pending_inputs`. A `running` session keeps that state; any other state changes to `pending`.
2. A worker claims a `pending` session by changing its state to `running`, merging the inbox into history, and clearing the inbox in the same update. Execution starts only if this update succeeds, so scheduling the same session repeatedly does not start multiple execution loops.
3. After each model and tool turn, the complete model output and its tool responses are saved together as a checkpoint. Inputs received during the turn are also merged into history, and the inbox is cleared.

Engine requests a pause if the model calls no tools or calls `wait_for_input`. It still processes the remaining tool calls in that turn, and later calls do not cancel the pause request. The session becomes `waiting` only when a pause was requested and the inbox is empty; otherwise, execution continues. The inbox merge and pause decision happen in the same database update, ensuring that input received during execution is included before the worker can pause.

## Service tasks and shutdown

An HTTP request that submits input returns `202 Accepted` after saving the input and scheduling a task. The service manages session tasks, which use its shared dependencies and the session ID. Execution continues even after the submitting request's connection closes.

The service uses `std.Io.Select` to wait for the listener task or a shutdown signal. The listener owns two `std.Io.Group` instances, one for HTTP connections and one for session workers. During shutdown, the service first cancels and waits for connection tasks, stopping new work. It then cancels and waits for session workers before releasing the shared HTTP client and database connection pool.

Model HTTP requests, database operations, SSH subprocesses, and execution loops use the same `std.Io`, with cancellation propagating through the task tree. The local SSH process also ends with its session task, but this does not establish whether the remote operation completed.

## Failure and recovery

A tool's `error` branch is saved in history as a tool result, leaving the model to decide what to do next. If a model request or the execution loop fails for a reason other than cancellation, Engine marks the session as `failed`. If saving that state also fails, the service logs the error. Cancellation ends execution without marking the session as failed.

New input or an explicit resume lets a failed session continue from its saved history. At startup, the service first changes any remaining `running` sessions to `pending`, then schedules all pending sessions. Recovery currently assumes one service process per application state database.

Session checkpoints and remote memory operations do not share a transaction. If memory changes but the service stops before saving its checkpoint, recovery may repeat the operation. Losing the connection or canceling the local wait also does not undo a completed remote change. When a memory change's outcome is uncertain, inspect the current content before deciding what to do next.
