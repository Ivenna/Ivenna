# Host shell

The [host tools](../packages/host/src/tools.json) let activity focuses run programs, inspect their output, and interact with them through the kernel's OS account on the shared host filesystem. Command references let activities discover and control running work.

| Tool | Purpose |
| --- | --- |
| `inspect_host_shell` | Inspect shell defaults and find commands |
| `run_host_shell` | Start a command and wait for completion up to a bounded duration |
| `continue_host_shell` | Read output, supply input, send a signal, or resize a terminal |

## Running a command

This `run_host_shell` call runs `make` in a project directory.

```json
{"name":"build","command":"make -j4","cwd":"/path/to/project"}
```

`yield_ms` limits the initial wait. Set `timeout_ms` to limit how long the command can run.

If execution and cleanup finish within the wait, the call returns the outcome and an output preview. If the wait ends first, the result includes a `command_id` for further interaction and a `callback_id` for the completion observation. Both IDs use the supplied name with independently assigned suffixes. The calling activity receives the observation even if the command finishes during the handoff.

| Argument | Meaning |
| --- | --- |
| `name` | Required short name for the work, used to form the [command ID](input.md#names-and-references) |
| `command` | Required command text, interpreted by the selected shell |
| `cwd` | Initial working directory. Defaults to the kernel's startup directory. Relative values resolve from that directory. |
| `shell` | Shell executable accepting `-c`. Defaults to `/bin/sh`. |
| `login` | Use `-lc` for the selected shell's login initialization. Defaults to `false`. |
| `mode` | Selects an [input mode](#input-modes). Defaults to `batch`. |
| `yield_ms` | Initial wait for completion in milliseconds. Defaults to `10000`. Use `0` to skip the wait. |
| `timeout_ms` | Optional execution limit in milliseconds. Use a positive duration. |
| `max_output_bytes` | Budget for the combined stdout and stderr previews after JSON escaping. Defaults to `4096` and accepts `512` through `16384`. Result metadata and log references are additional. |

Each command starts a fresh shell. The `cwd` and `shell` arguments accept literal paths or local `file://` URIs. Inside `command`, the shell expands expressions and resolves relative paths from its current directory. A shell running in an interactive [input mode](#input-modes) can retain directory and environment changes across calls.

### Command environment

The inherited environment requests plain output with `NO_COLOR=1` and pagers set to `cat`. `TERM` is `dumb`, or `xterm-256color` in terminal mode. Login initialization can change the environment and working directory.

Host commands receive the absolute path to the `ivenna` executable as `IVENNA` and the canonical absolute path to the instance's data directory as `DATA_DIR`. A program in any input mode can use this environment to [receive channel messages](communication.md#receiving-from-a-channel) or [publish subscription observations](subscriptions.md#publish-an-observation).

## Input modes

| Mode | Input and output |
| --- | --- |
| `batch` | No live stdin. Separate stdout and stderr logs. |
| `pipe` | Writable stdin until EOF. Separate stdout and stderr logs. |
| `terminal` | A pseudo-terminal for programs that require one. Stdout and stderr share the stdout log. |

This call starts an interactive Python process in a terminal and returns an immediate observation.

```json
{"name":"python","command":"python3 -u -i","mode":"terminal","yield_ms":0}
```

A terminal starts with 24 rows and 80 columns and can be resized. The tool returns its output stream without rendering a screen. Use `batch` or `pipe` when you need byte-preserving output. See the [runtime requirements](running.md#runtime-requirements) for terminal support.

## Continuing and controlling a command

Use the complete `command_id` returned when `run_host_shell` hands off a command, or find it with `inspect_host_shell`. A command appears in the shared list while its starting activity is still waiting.

Call `inspect_host_shell` with `{}` to list commands or pass `{"command_id":"build-17"}` to select one. Each entry gives the `command_id`, the `focus_id` that started it, its `state`, `mode`, `stdin_open`, and `input_pending`. A pending write is still in flight. The first unfiltered page also gives the default `shell` and startup `cwd`.

The result includes the requested `offset` (zero by default) and the number of matching commands in `total_commands`. Pass `next_offset` as the next call's `offset` to read another page. A null `next_offset` marks the end. An offset beyond the list returns no commands. Pages reflect the current registry order, which can change as commands retire.

Call `continue_host_shell` with the selected `command_id`. This example omits `action` to read more output.

```json
{"command_id":"build-17","yield_ms":1000,"max_output_bytes":4096}
```

The continuation starts the requested action before waiting for unread output or completion. `yield_ms` sets that wait, with a default of `1000` milliseconds. Use `0` to skip the wait. The command keeps its existing execution deadline. `max_output_bytes` uses the same budget and default as `run_host_shell`.

Select exactly one operation when supplying `action`.

| Action | Example | Effect |
| --- | --- | --- |
| Read | `{"read":{}}` | Observe output and status without supplying input |
| Write | `{"write":{"text":"print(1 + 1)\n"}}` | Supply text to a pipe or terminal. Optional `eof` follows the mode's rules below. |
| Signal | `{"signal":{"name":"interrupt"}}` | Send `interrupt` (SIGINT), `terminate` (SIGTERM), or `kill` (SIGKILL) |
| Resize | `{"resize":{"rows":40,"cols":120}}` | Change dimensions in terminal mode |

`eof: true` in `action.write` closes pipe stdin for the rest of the command after writing the supplied text. In terminal mode it sends Ctrl-D and leaves the terminal writable.

Each write accepts at most 4096 Unicode code points and proceeds independently of the observation call. `stdin.pending` identifies a write still in flight. Another write returns `input_busy` until it finishes. An optional `stdin.error` describes a failed or interrupted write. Some input may already have reached the program. Check its response before repeating that input.

Interrupt targets the terminal's foreground group, or the command's process group without a terminal. Terminate and kill cover the original terminal session or command group. A program can handle or ignore SIGINT and SIGTERM; SIGKILL forces termination. Output remains available for collection afterward.

## Output and results

Command observations give the process state and available output. Nonzero exits, signals, execution timeouts, and an OS failure to start a command appear as outcomes in `state`.

| Result field | Meaning |
| --- | --- |
| `command_id` | Handle returned for a handoff or continuation. See [command lifetimes](#command-lifetimes). |
| `callback_id` | Reference for the completion observation arranged by the initial call |
| `state.running` | The command is still running |
| `state.finished` | `completed` with an OS termination status (for example, `{"completed":{"exited":7}}`), `timed_out`, or `not_started` with a reason |
| `state.unavailable` | The command started, but the host could not establish a complete outcome. `reason` explains what is unavailable. |
| `elapsed_ms` | Monotonic elapsed time, fixed when Host observes the process outcome |
| `mode` | The command's [input mode](#input-modes) |
| `stdin` | Whether input is `open`, whether a byte-stream write is `pending`, and an optional write `error` |
| `stdout`, `stderr` | A string when the result includes the whole log as text. Partial text and binary output carry the full log's `path` and current `byte_length`. A stream with no bytes to return is omitted. |
| `output_error` | Indicates that the retained output could not be read. Each stream then supplies its log `path` alongside the observed process state. |

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

If a command writes a PDF to stdout, pass its returned log `path` to `read_resource` as `location` with `"view":"file"`. To keep it in memory, pass the same path to `remember.content.file.path`. Redirect output to a named file when you need a path even for short or empty output. For example, use `generate-report > report.txt`. See [local reads](resources.md#local-files-and-directories) and [recording a memory](memory.md#recording).

## Command lifetimes

Control handles work in the runtime that issued them for as long as it retains them. Each command handed off by its initial call has one completion observation registered for the activity that started it. The observation still goes to that activity when another activity controls the command or drains its output. The registration keeps the originating activity available to receive it after sleep or restart. See [activity completion](attention.md#activity-completion).

`MAX_HOST_COMMANDS` limits live commands across all activities. Completion releases live capacity. A final result returned directly by `run_host_shell` retires its handle. Finished background handles remain available in a bounded cache for recent output collection; a continue call that drains one retires it, and older finished handles can be reclaimed for other commands. See [command lifecycle](architecture.md#command-lifecycle) for the cache limit. Full logs have a [separate retention lifecycle](running.md#host-output-and-deployment-files).

Shutdown stops managed commands and waits for cleanup, including jobs merely backgrounded with `&`. Work that creates another OS session has an independent lifetime. If it holds the original terminal open, the final result can report that output collection timed out. See [process ownership and cleanup](architecture.md#processes-and-terminals).

After restart, old command IDs identify earlier executions. A pending completion delivers its stored result when available, or an interruption observation with the outcome unknown. An interrupted call can already have produced effects. Check those effects before repeating it. See [startup and interruption](architecture.md#startup-and-interruption).

## Errors

Errors describe the failed operation and indicate what effects may already have occurred. Host debug logs carry platform error names for diagnosis.

| Code | Meaning |
| --- | --- |
| `invalid_arguments` | The invocation does not match the tool's arguments |
| `commands_unavailable` | No live-command slot is available; the command was not started |
| `unknown_command` | The handle is unknown or was retired; full logs have a separate lifetime |
| `command_finished` | An input or control action targeted a finished command; read its remaining output instead |
| `stdin_closed` | The command has no writable input, including batch mode and a pipe after EOF |
| `input_busy` | A previous input write is still in flight |
| `control_failed` | A signal or terminal resize failed. The message gives the available reason. |
| `host_unavailable` | The host could not prepare the command's logs or collect its output. The response indicates whether the command could have produced effects. |

If the initial preview fails after registration, `host_unavailable` comes with the observed state, log paths, `output_error`, and both IDs. Use the `command_id` to observe the command again. The `callback_id` identifies the completion observation still due to the activity.

These defined errors remain tool observations. Failures of task scheduling or runtime supervision follow the [runtime availability](design.md#runtime-availability) contract and end the runtime.
