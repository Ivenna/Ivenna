# Host shell

The [host tools](../packages/host/src/tools.json) let activity focuses run programs, inspect their output, and interact with them through the kernel's OS account on the shared host filesystem. Command references let activities discover and control running work.

| Tool | Purpose |
| --- | --- |
| `inspect_host_shell` | Inspect shell defaults and find commands or their channels |
| `run_host_shell` | Start a command and wait for completion up to a bounded duration |
| `continue_host_shell` | Read output, supply input, send a signal, or resize a terminal |

## Running a command

Call `run_host_shell` to start a command:

```json
{"name":"build","command":"make -j4","cwd":"/path/to/project"}
```

`yield_ms` controls how long the caller waits. A command can keep running after the call returns. Set `timeout_ms` to limit its execution time.

If execution and cleanup finish within the wait, the call returns the outcome and an output preview. Otherwise it returns a `command_id` for further interaction and a `callback_id` for the completion observation. Both IDs use the supplied name and have independently assigned numeric suffixes. The calling activity will receive the observation even if the command has already finished by the time the call returns.

The tool wait retains the current activation and context while the core and other activities continue. After the complete model/tool round, the next inference receives the tool reply together with newly admitted observations.

| Argument | Meaning |
| --- | --- |
| `name` | Required short name used to form the [command ID](input.md#names-and-references) |
| `command` | Required command text, interpreted by the selected shell |
| `cwd` | Initial working directory. Defaults to the kernel's startup directory. Relative values resolve from that directory. |
| `shell` | Shell executable accepting `-c`; defaults to `/bin/sh` |
| `login` | Use `-lc` for the selected shell's login initialization; defaults to `false` |
| `mode` | `batch` (default), `pipe`, `messages`, or `terminal`; see [input modes](#input-modes) |
| `yield_ms` | This call's wait for completion in milliseconds, from `0` through `4294967295`; omit for `10000`, or use `0` to observe immediately |
| `timeout_ms` | Optional positive execution deadline in milliseconds, up to `4294967295`; omitted means no execution deadline |
| `max_output_bytes` | Combined encoded stdout/stderr preview budget in bytes. Defaults to `4096` and accepts `512` through `16384`. Result metadata and log references are additional. |

Each command starts a fresh shell. The `cwd` and `shell` arguments accept literal paths or local `file://` URIs. Inside `command`, the shell expands expressions and resolves relative paths from its current directory. A shell running in an interactive [input mode](#input-modes) can retain directory and environment changes across calls.

### Command environment

The inherited environment requests plain output with `NO_COLOR=1` and pagers set to `cat`. `TERM` is `dumb`, or `xterm-256color` in terminal mode. Login initialization can change the environment and working directory.

Host commands receive the absolute path to the `ivenna` executable as `IVENNA` and the absolute path to the instance's data directory as `DATA_DIR`.

## Input modes

| Mode | Input and output |
| --- | --- |
| `batch` | No live stdin; stdout and stderr have separate logs |
| `pipe` | Writable stdin until EOF is sent; stdout and stderr have separate logs |
| `messages` | [Whole messages on stdin](#receiving-messages-in-a-command), with separate stdout and stderr logs |
| `terminal` | A pseudo-terminal for programs that require a terminal; stdout and stderr are merged into the stdout log |

For example, start an interactive Python process in a terminal and return immediately:

```json
{"name":"python","command":"python3 -u -i","mode":"terminal","yield_ms":0}
```

A terminal starts with 24 rows and 80 columns and can be resized. The tool returns its output stream without rendering a screen. Terminal processing can alter input and output bytes; use `batch` or `pipe` when bytes must be preserved. See the [runtime requirements](running.md#runtime-requirements) for terminal support.

### Receiving messages in a command

Start the command in `messages` mode and set `yield_ms` to `0` to get its `command_id` while it waits for input. Use the ID to [open a channel](communication.md#opening-a-channel). In this example, the receiver prints each message to the command's [stdout log](running.md#host-output-and-deployment-files).

```json
{"name":"worker","command":"exec \"$IVENNA\" receive --follow","mode":"messages","yield_ms":0}
```

Keep the command's inherited stdin when invoking `receive` from a script. For a single read, call `"$IVENNA" receive` to check immediately or `"$IVENNA" receive --wait MS` to wait up to `MS` milliseconds. A successful single read writes one JSON line to stdout and exits with code 0.

| JSON on stdout | Meaning |
| --- | --- |
| `{"status":"message","text":"Process the next item."}` | One message was read. |
| `{"status":"empty"}` | The immediate check found no message. |
| `{"status":"timeout"}` | The wait ended before a message arrived. |
| `{"status":"closed"}` | End of input after any pending message has been read. |

For a stream, call `"$IVENNA" receive --follow` to wait for successive messages and flush each `message` object as a JSON line. A script can pipe stdout to a handler. The receiver exits with code 0 after draining closed input or when the output pipe closes. The stream contains only `message` records.

Reading a message makes room for the next send, even if the script is still processing it. Run `"$IVENNA" receive --help` for option limits and exit codes. See [reporting from a command](subscriptions.md#reporting-from-a-command) to send observations back to a focus.

## Continuing and controlling a command

Use the complete `command_id` returned by a yielded `run_host_shell` call or listed by `inspect_host_shell`. Commands are discoverable across activities, including while the starting activity is still waiting in `run_host_shell`.

Call `inspect_host_shell` with `{}` to list commands. The first unfiltered page also gives the default `shell` and startup `cwd`. To inspect one command, pass its ID, for example `{"command_id":"build-17"}`. Each entry in `commands` includes the `command_id`, originating `focus_id`, a `command_preview`, `state`, `mode`, `stdin_open`, and `input_pending`. A command with an open channel also shows its `channel_id`.

`input_pending` reports a write in flight to a pipe or terminal. For a channel, use the [result of `send`](communication.md#sending-to-a-channel) to see whether the runtime accepted a message.

The result includes the requested `offset` (zero by default) and the number of matching commands in `total_commands`. Pass `next_offset` as the next call's `offset` to read another page. A null `next_offset` marks the end. An offset beyond the list returns no commands. Pages reflect the current registry order, which can change as commands retire.

Call `continue_host_shell` with the selected `command_id`. Omit `action` to read more output:

```json
{"command_id":"build-17","yield_ms":1000,"max_output_bytes":4096}
```

For a continuation, the tool applies the action before waiting for unread output or completion. Set `yield_ms` to control that observation wait. The default is `1000` milliseconds, `0` inspects immediately, and values through `4294967295` are supported. The command keeps its existing execution deadline. `max_output_bytes` has the same range and default as `run_host_shell`.

The optional `action` selects exactly one operation:

| Action | Example | Effect |
| --- | --- | --- |
| Read | `{"read":{}}` | Observe output and status without supplying input |
| Write | `{"write":{"text":"print(1 + 1)\n"}}` | Supply text to a pipe or terminal; optional `eof` ends input after that text |
| Signal | `{"signal":{"name":"interrupt"}}` | Send `interrupt` (SIGINT), `terminate` (SIGTERM), or `kill` (SIGKILL) |
| Resize | `{"resize":{"rows":40,"cols":120}}` | Change dimensions in terminal mode |

`eof: true` in `action.write` closes pipe stdin after the supplied text; later writes cannot reopen it. In terminal mode it sends Ctrl-D and leaves the transport writable.

Each write accepts at most 4096 Unicode code points and proceeds independently of the observation call. `stdin.pending` identifies a write still in flight; another write returns `input_busy` until it finishes. An optional `stdin.error` reports a failed or canceled write. Some input may already have reached the program when an error occurs; inspect its response before repeating that input.

Interrupt targets the terminal's foreground group, or the command's process group without a terminal. Terminate and kill cover the original terminal session or command group. A program can handle or ignore SIGINT and SIGTERM; SIGKILL forces termination. Output remains available for collection afterward.

## Output and results

Command observations report the process state and any output available in this observation. Nonzero exits, signals, execution timeouts, and an OS failure to start a command are ordinary outcomes.

| Result field | Meaning |
| --- | --- |
| `command_id` | Host command identity, returned for a handoff or continuation; usable as a handle only in its originating runtime while retained |
| `callback_id` | Reference for the completion observation arranged by the initial call |
| `state.running` | The command is still running |
| `state.finished` | `completed` with an OS termination status (for example, `{"completed":{"exited":7}}`), `timed_out`, or `not_started` with a reason |
| `state.unavailable` | The host could not establish a complete outcome; `reason` describes the failure |
| `elapsed_ms` | Monotonic elapsed time, fixed when Host observes the process outcome |
| `mode` | The selected `batch`, `pipe`, `messages`, or `terminal` mode |
| `stdin` | Whether input is `open`, whether a byte-stream write is `pending`, and an optional write `error` |
| `stdout`, `stderr` | A string when the whole log so far fits as text. Partial text and binary output carry the full log's `path` and current `byte_length`. A stream with no new bytes is omitted. |
| `output_error` | Reason output collection failed. Each stream then supplies its log `path` alongside the observed process state. |

This pipe command printed `ready` before its initial wait expired.

```json
{
  "result": {
    "command_id": "build-17",
    "callback_id": "build-5",
    "state": {"running": {}},
    "elapsed_ms": 10002,
    "mode": "pipe",
    "stdin": {"open": true, "pending": false},
    "stdout": "ready\n"
  }
}
```

The portion of the log you see depends on how you observe the command.

| Observation | Output |
| --- | --- |
| Initial call with a `callback_id` | Reads from byte zero independently of other activities. A later continuation can show the same bytes. |
| `continue_host_shell` | Reads forward from one shared cursor per stream. A read by one activity advances the cursor for all activities. |
| Direct final result or completion callback | Shows the beginning and end of long text with an omitted-byte count, independently of the cursors. The callback identifies the command in `source.host.command_id`. See [callback observations](input.md#callback-observations). |

On the initial handoff and on continuations, a log object gives the byte `range` read, from `offset` up to but excluding `next_offset`. A text `preview` contains the characters in that range. Binary output omits the preview. Each stream's preview fits its share of `max_output_bytes` after JSON escaping.

The core or an activity can open a log by its returned `path`, even after the command handle expires. Reading the file leaves the command's cursors in place. A `path` or `cwd` containing non-UTF-8 bytes is returned as a local file URI.

To open a generated PDF, pass the log's `path` to `read_resource` as `location` with `"view":"file"`. To keep it in memory, pass the same path to `remember.content.file.path`. If you need a file even when output is short or empty, redirect the command to a named file, for example `generate-report > report.txt`. See [local reads](resources.md#local-files-and-directories) and [recording a memory](memory.md#recording).

## Command lifetimes

Complete command references identify executions. Their numeric suffixes advance across restarts, while control handles remain available only in their originating runtime. Callback references connect the initial handoff with its later observation and remain retained across restart. A command handed off by its initial call remains owned by the host runtime and has one completion observation registered for its originating activity. That registration keeps the activity available across sleep until the observation is durably admitted. Reading or controlling the command from another activity does not redirect its completion. The `focus_id` in inspection records identifies where the command started.

Command state, handle retention, and the registered observation have separate lifetimes. Draining a handle does not cancel its completion observation; cancellation is unavailable. A response without tool calls lets the activity sleep while an observation remains registered. See [activity completion](attention.md#activity-completion) for the conditions under which it sleeps or ends.

`MAX_HOST_COMMANDS` limits live commands across all activities. Completion releases live capacity. A final result returned directly by `run_host_shell` retires its handle. Finished background handles remain available in a bounded cache for recent output collection; a continue call that drains one retires it, and older finished handles can be reclaimed for other commands. See [command lifecycle](architecture.md#command-lifecycle) for the cache limit. Full logs have a [separate retention lifecycle](running.md#host-output-and-deployment-files).

Shutdown stops commands and waits for cleanup. Batch, pipe, and messages commands are managed by process group. Terminal cleanup covers its original OS session, including background jobs in separate job-control groups. Shell backgrounding with `&` remains within this managed lifetime. Work that creates another OS session has an independent lifetime. If it holds the original terminal open, final output draining ends after one second with an unavailable-result diagnostic. The [architecture guide](architecture.md#processes-and-terminals) describes process ownership and cleanup.

Host processes and handles are not restored after restart, and commands are not replayed. A pending host completion is resolved with an observation of interruption and unknown effects if no result was already stored. A stored actual result takes precedence. A command ID in a restored observation identifies an execution in the earlier runtime, not a usable current handle. An interrupted call may also have produced effects without a saved outcome; inspect uncertain effects before repeating work. See [startup and interruption](architecture.md#startup-and-interruption).

## Errors

Errors describe the failed operation without erasing effects already produced. Defined tool errors include:

| Code | Meaning |
| --- | --- |
| `invalid_arguments` | The invocation does not match the tool's arguments |
| `commands_unavailable` | No live-command slot is available; the command was not started |
| `handoff_unavailable` | The call had no destination for its completion observation; the started command was stopped and joined, with its observed outcome and logs retained in the result |
| `unknown_command` | The handle is unknown or was retired; full logs have a separate lifetime |
| `command_finished` | An input or control action targeted a finished command; read its remaining output instead |
| `stdin_closed` | The command has no writable input, including batch mode and a pipe after EOF |
| `message_input_only` | To send input to a messages-mode command, open a channel and use `send` with its `channel_id` |
| `input_busy` | A previous input write is still in flight |
| `control_failed` | A signal or terminal resize failed, with its diagnostic |
| `host_unavailable` | The host operation could not supply a complete result; effects may already have occurred |

`handoff_unavailable` returns `error` and `result` together. If output collection also fails, the result retains the observed state and log paths with an `output_error`. No completion observation was arranged for that failed handoff.

An initial preview read can instead fail after registration succeeds, returning `host_unavailable` with a result containing `command_id`, `callback_id`, observed status, log paths, and `output_error`. The returned callback ID confirms that the completion observation remains arranged.

These defined errors remain tool observations. Failures of task scheduling or runtime supervision follow the [runtime availability](design.md#runtime-availability) contract and end the runtime.
