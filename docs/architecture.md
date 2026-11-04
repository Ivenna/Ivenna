# Architecture

Ivenna receives input over HTTP and runs model requests and tool calls in persistent sessions. Embedded SQLite stores application state, host command output lives in local files, and autonomous memory lives in a file workspace accessed over SSH.

This guide describes the current implementation of the project's [design intent](design.md), including module boundaries, model input, and session execution.

## Module responsibilities

`apps/server` depends on `packages/agent`. It assembles the shared HTTP client, session store, and execution engine in [main.zig](../apps/server/src/main.zig) and manages the service lifecycle.

Api accepts input and schedules session execution. Engine loads history from Store, interacts with the model through Provider, invokes tools, and checkpoints the model and tool results in Store.

| Module | Responsibility |
| --- | --- |
| [Api](../apps/server/src/api.zig) | Handle HTTP requests, schedule session tasks, and manage connection and task lifecycles |
| [Engine](../packages/agent/src/root.zig) | Create sessions, run model and tool loops, and save each turn's results |
| [Provider](../packages/agent/src/provider.zig) | Encode model requests and tool results, decode typed function calls, and apply local image request checks |
| [Store](../packages/agent/src/store.zig) | Persist sessions, history, and the input inbox, and apply session state transitions |
| [Memory](../packages/agent/src/memory.zig) | Resolve write sources, exchange structured requests with the remote handler, and return operation results |
| [Host](../packages/agent/src/host.zig) | Parse and route shell requests with trusted conversation context, and select their returned content |
| [content.zig](../packages/agent/src/content.zig) | Define shared content types and classify source bytes |

HTTP and concurrency use the Zig standard library. SQLite is compiled into the application, input serialization to YAML uses `yaml-zig`, and image format recognition uses [zignal](https://github.com/arrufat/zignal). Dependency versions are pinned in the [agent package manifest](../packages/agent/build.zig.zon). See the [development guide](development.md) for the repository layout and build commands.

## Local data and diagnostics

The service resolves `DATA_DIR` from its startup directory and creates it when needed. The default is `.ivenna`. Store opens `<DATA_DIR>/state.sqlite`; Shell writes output files under `<DATA_DIR>/host/`. The SSH memory workspace is configured separately. These locations hold the deployment user's data; see [local data](running.md#local-data) for setup and ownership.

Session state and history are the records used to continue execution. Host output files retain command results beyond the model's bounded previews. Diagnostic messages currently go to the service's stderr. Dedicated diagnostic storage, retention controls, and telemetry export remain future work; their interfaces and formats are undecided.

## Application state and autonomous memory

Store updates session state, history, and the input inbox atomically in SQLite, using the current structure in [schema.sql](../packages/agent/src/schema.sql). A mutex serializes access to one connection, and transactions keep inbox merges and their state transitions together. Engine reads only saved history for each turn; full session snapshots serve the HTTP API.

A session can be `waiting`, `pending`, `running`, or `failed`; a `failed` state also carries an error name. See [API and session records](usage.md#api-and-session-records) for the HTTP representation.

Autonomous memory is shared across all sessions. The model chooses memory operations and supplies arguments through the structured tools defined in [tools.json](../packages/agent/src/tools.json). Memory encodes each request as a JSON object containing a single operation and sends it to the SSH process's standard input. For example, a read request is:

```json
{"read_memory":{"address":"languages/progress.md","expected":{"auto":{}}}}
```

The remote handler, [memory.nu](../packages/agent/src/memory.nu), runs at a fixed path, fills in default values for omitted arguments, and checks that addresses resolve within the memory workspace. It uses [fd](https://github.com/sharkdp/fd) to find names, [ripgrep](https://github.com/BurntSushi/ripgrep) to search content, and Nushell built-ins to read, write, and organize entries. The handler runs predefined operations, treating content and match expressions supplied by the model as data.

The memory tools use Nushell's operation boundaries as a reference. Like [`ls`](https://www.nushell.sh/commands/docs/ls.html), `browse_memory` combines listing and metadata queries, with recursive size measurement requested explicitly. Content reads use [`open --raw`](https://www.nushell.sh/commands/docs/open.html); recording uses [`save --raw`](https://www.nushell.sh/commands/docs/save.html) with create, append, or replace behavior. Name and content searches remain separate from literal-address browsing.

For `remember`, Memory resolves the selected text or host-file source before starting SSH. Text becomes UTF-8 bytes; file contents are read without format detection or conversion. Both sources use base64 in the internal request's `data` field. The remote handler decodes these bytes and writes them according to the requested mode. Source-file paths stay local to the application. A local read failure returns `source_unavailable` without sending a remote request.

The handler returns either a `result` branch with exit code `0` or an `error` branch with exit code `1`. A successful read carries the entry's raw bytes as base64 in `data`, together with its `address`. Memory decodes these bytes and uses the shared classifier to construct its tool result. Other operations retain their JSON result structure.

Memory storage and address-based operations accept arbitrary file types. Text revision requires UTF-8 without NUL bytes; the handler rejects other content before writing. Model-facing reads support the content types described in [tool content](content.md).

Reads and writes currently buffer complete files and JSON payloads in the application and remote handler. Transfer memory usage therefore grows with file size. Incremental transfers remain future work; the streaming protocol and buffering limits are undecided.

Memory verifies that the response and exit code agree, then passes operation errors back to the model. If the SSH exchange ends without a complete, consistent reply, including malformed read data, Memory logs the diagnostics and returns an error indicating that memory is unavailable or that the outcome of a change is uncertain. Errors starting SSH, collecting its output, or waiting for it to exit propagate to session failure handling. See [memory rooms](memory.md) for tool usage and [using remote memory](running.md#using-remote-memory) for deployment.

### Memory size and capacity

`inspect_memory_space` follows the same Memory request path as the other memory tools. The remote handler measures the shared workspace against `MEMORY_CAPACITY_BYTES`; the deployment user sets this capacity in the [memory backend's environment](running.md#changing-configuration). The [memory guide](memory.md#memory-space) defines the model-facing result and capacity behavior.

The handler recursively sums regular-file lengths, including hidden files and child directories. Directories, symlinks, and special files do not contribute to the total; each hard-linked name is counted separately. A scan failure returns an operation error instead of a partial total.

`browse_memory` obtains file lengths from metadata. Directory sizes remain unmeasured unless `recursive_size` is requested, in which case it reuses the strict recursive count. `size_bytes` uses the same logical content lengths as capacity checks.

Before recording or revising content, the handler projects the resulting total, accounting for hard-linked names affected by a change, and rejects growth beyond capacity. The [memory shell](../dev/memory/memory-shell.sh) holds a workspace lock through each handler invocation, keeping measurement, capacity checks, and writes together across SSH calls. Direct filesystem changes can bypass these checks, and storage failures use the normal operation error path.

## Host execution

Host validates tool arguments, routes requests, and selects the content returned to Engine. Its implementation is divided by responsibility:

| Component | Responsibility |
| --- | --- |
| [Shell](../packages/agent/src/host/shell.zig) | Describe shell capabilities and execute commands; own future process and terminal control |
| [Reader](../packages/agent/src/host/reader.zig) | Classify captured stdout and return text previews, images, or URL references |
| [process.zig](../packages/agent/src/host/process.zig) | Spawn subprocesses, enforce timeouts, stop process groups, and reap direct children |
| [output.zig](../packages/agent/src/host/output.zig) | Read bounded file previews and preserve valid UTF-8 boundaries |

Shell returns a typed execution result containing the process outcome, output streams, and log paths. Host turns it into content for Engine. The [host guide](host.md#results-and-interruption) defines the model-facing replies.

### Command execution

Engine supplies the current session ID in `Host.Context`. Shell uses this trusted identity to group output files under `<DATA_DIR>/host/<session_id>/`. All sessions execute as the service's OS account and share its filesystem.

Shell executes one command per invocation with a copy of the service's inherited environment, including `PATH`, and overrides for batch output. Changing the command's working directory does not reload that environment. Each command runs through a noninteractive `/bin/sh` and writes full stdout and stderr to files. Reader classifies stdout according to the command's `expected` hint; stderr uses the text-preview helper. When the shell exits, times out, or is canceled, the process helper stops any remaining processes in the invocation's process group and reaps the direct child. The [host guide](host.md) defines the tool arguments and results; the [running guide](running.md#optional-host-tools) covers program availability.

### Planned process control

Command execution is the first implementation of the Shell boundary. `Shell.Capabilities` marks it as available and reserves the following controls as planned:

| Capability | Responsibility |
| --- | --- |
| `process_sessions` | Keep live process handles and provide incremental output |
| `stdin` | Send input and EOF to a running process |
| `pty` | Provide terminal transport |
| `process_control` | Interrupt or terminate a running process |
| `background_jobs` | Schedule conversation work when a background process completes |

These entries identify planned capabilities; no LLM operations implement them yet. A future design needs to address process state that outlives model-turn arenas, the relationship between process handles and conversation identity, and scheduling a paused conversation when background work completes. The operation interfaces and restart behavior remain undecided.

[Pi's bash tool](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/src/core/tools/bash.ts) provides a reference for bounded model output with full logs. [Codex's resumable execution tools](https://github.com/openai/codex/blob/main/codex-rs/core/src/tools/handlers/shell_spec.rs) inform process continuation and input; [OpenCode's background shell jobs](https://github.com/anomalyco/opencode/blob/dev/packages/core/src/tool/plugin/shell.ts) illustrate completion scheduling. These references guide later shell controls.

## Tool content

[content.zig](../packages/agent/src/content.zig) defines shared content expectations and types. Its classifier inspects one byte sequence and returns text, an image, or an unavailable-content diagnostic. Image sources are encoded bytes or URL references. [image.zig](../packages/agent/src/image.zig) recognizes format signatures through zignal; the classifier applies the per-image byte limit and text checks. Classification borrows the source bytes without decoding pixels or fetching URL references. See [tool content](content.md) for expectations, URL interpretation, and supported types.

Memory and Host return a `Content` value to Engine, which passes it to Provider for model protocol encoding.

Memory and Reader keep returned text, image bytes, and URL strings in the caller's turn arena. Memory copies or decodes data out of temporary SSH buffers before returning. Reader checks recognized image sizes before allocating their bytes.

Memory reads retain full text. Reader produces bounded shell text previews and, for large non-image output, checks only the head and tail used in the preview. An image expectation with URL representation reads stdout in full. Classifying omitted preview bytes incrementally remains future work.

## Model input and history

When creating a session, Engine saves its default input fields and adds the sole system message:

> Je pense, donc je suis.

Subsequent HTTP inputs are merged with the session defaults by [input.zig](../packages/agent/src/input.zig). The session ID is added, and the result is serialized to YAML as a user message for the model. See [input fields](usage.md#input-fields) for the merge rules.

Provider sends the compiled definitions in [tools.json](../packages/agent/src/tools.json) with every model request to DeepSeek's native `/responses` endpoint. It decodes the complete response and validates function-call envelopes before returning typed calls to Engine, so malformed output fails before any tool in that response executes. Returned data belongs to the turn's arena and survives cleanup of the HTTP response buffer.

Engine receives typed function calls and retains the complete `output`, including reasoning, messages, and function calls, for history replay. The selected tool validates its arguments; an unknown tool or invalid arguments produce a tool error that the model can act on.

Provider encodes each tool result in a `function_call_output` with the corresponding `call_id`. Text becomes an `output` string. An image becomes an `output` array containing one `input_image` part, following DeepSeek's [Responses image input format](https://api-docs.deepseek.com/guides/responses_api/#image-input). Engine appends the encoded results to history for the next model request.

Provider applies the [local image request checks](content.md#model-request-checks) as each image result is encoded. Before checkpointing, it checks the completed tool batch's request size and replaces new image results, newest first, with text `content_limit` errors until the request fits or no new images remain.

Earlier history and text results are preserved. They can exceed the request-size threshold on their own, and inputs merged by Store at checkpoint can increase request size after the checks.

Provider embeds local image bytes as base64 data URLs before checkpointing, so replay is independent of the original files. Remote URLs are retained as supplied and fetched by DeepSeek on later requests; their content can change or become unavailable.

Engine reloads saved history from Store at the start of each loop iteration and sends it in full through Provider. Each iteration uses its own arena and releases its temporary data after saving a checkpoint. Persisted history continues to grow; it is not currently compacted or trimmed.

## Sessions and checkpoints

The session ID stays the same across subsequent inputs, pauses, and resumes. Creating a session only saves its initial data; submitting input or explicitly resuming the session schedules execution. The input and checkpoint flow updates the session at three points:

1. Submitting input appends the message to `pending_inputs`. A `running` session keeps that state; any other state changes to `pending`.
2. A worker claims a `pending` session by changing its state to `running`, merging the inbox into history, and clearing the inbox in the same update. Execution starts only if this update succeeds, so scheduling the same session repeatedly does not start multiple execution loops.
3. After each model response and its tool calls, the complete model output and tool responses are saved together as a checkpoint. Inputs received during the turn are also merged into history, and the inbox is cleared.

Engine requests a pause if the model calls no tools or calls `wait_for_input`. It still processes the remaining tool calls in that turn, and later calls do not cancel the pause request. The session becomes `waiting` only when a pause was requested and the inbox is empty; otherwise, execution continues. The inbox merge and pause decision happen in the same database transaction, ensuring that input received during execution is included before the worker can pause.

## Service tasks and shutdown

An HTTP request that submits input returns `202 Accepted` after saving the input and scheduling a task. The service manages session tasks, which use its shared dependencies and the session ID. Execution continues even after the submitting request's connection closes.

The service uses `std.Io.Select` to wait for the listener task or a shutdown signal. The listener owns two `std.Io.Group` instances, one for HTTP connections and one for session workers. During shutdown, the service first cancels and waits for connection tasks, stopping new work. It then cancels and waits for session workers before releasing the shared HTTP client and closing the database.

Model HTTP requests, SSH and host subprocesses, and execution loops use the same `std.Io`, with cancellation propagating through the task tree. Host command timeouts and cancellation terminate the command's process group. The local SSH process also ends with its session task, but this does not establish whether the remote operation completed.

## Failure and recovery

A tool's `error` branch is saved in history as a tool result, leaving the model to decide what to do next. If a model request or the execution loop fails for a reason other than cancellation, Engine marks the session as `failed`. If saving that state also fails, the service logs the error. Cancellation ends execution without marking the session as failed.

New input or an explicit resume lets a failed session continue from its saved history. At startup, the service first changes any remaining `running` sessions to `pending`, then schedules all pending sessions. Recovery currently assumes one service process per application state database.

Session checkpoints, remote memory operations, and host command effects do not share a transaction. If a tool changes memory or host files but the service stops before saving its checkpoint, recovery may repeat the operation. Losing the connection, timing out, or canceling the local wait also does not undo completed changes. When a tool's outcome is uncertain, inspect the current state before deciding what to do next.

Re-executing a `remember` file-source call reads the current host file again; session history retains the source path rather than the transferred bytes.
