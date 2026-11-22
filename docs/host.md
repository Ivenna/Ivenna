# Host shell

The [host tools](../packages/host/src/tools.json) let activity focuses run programs, inspect their output, and interact with them through the kernel's OS account on the shared host filesystem. Command references let activities discover and control running work.

| Tool | Purpose |
| --- | --- |
| `inspect_host_shell` | Inspect shell defaults and discover command handles |
| `run_host_shell` | Start a command and wait for completion up to a bounded duration |
| `continue_host_shell` | Read output, supply input, send a signal, or resize a terminal |

## Running a command

Call `run_host_shell` to start a command:

```json
{"name":"build","command":"make -j4","cwd":"/path/to/project"}
```

`yield_ms` bounds how long this call waits for completion: it defaults to `10000` milliseconds, and `0` returns an immediate observation. Returning from the wait leaves unfinished execution running. `timeout_ms` separately limits how long the command may execute before it is stopped.

If execution and cleanup finish within the wait, the call returns the final outcome with a complete-source output preview. Otherwise it returns a complete `command_id` for interaction and a `callback_id` for one completion observation bound to the calling activity. Both use the supplied name as their prefix and have independently assigned numeric suffixes. The activity can continue reasoning without polling for completion. A returned `callback_id` confirms that registration even if the command has finished by the time its result snapshot is taken.

The tool wait retains the current activation and context while the core and other activities continue. After the complete model/tool round, the next inference receives the tool reply together with newly admitted observations.

| Argument | Meaning |
| --- | --- |
| `name` | Required short name; the runtime appends a number to form the command reference; names may repeat |
| `command` | Required command text, interpreted by the selected shell |
| `cwd` | Working directory, absolute or relative to the kernel's startup directory; defaults to that startup directory |
| `shell` | Shell executable accepting `-c`; defaults to `/bin/sh` |
| `login` | Use `-lc` for the selected shell's login initialization; defaults to `false` |
| `mode` | `batch` (default), `pipe`, or `terminal`; see [input modes](#input-modes) |
| `yield_ms` | This call's wait for completion in milliseconds, from `0` through `4294967295`; omit for `10000`, or use `0` to observe immediately |
| `timeout_ms` | Optional positive execution deadline in milliseconds, up to `4294967295`; omitted means no execution deadline |
| `max_output_bytes` | Combined encoded stdout/stderr preview budget, from `512` through `16384` bytes; defaults to `16384`; result metadata and log paths are additional |
| `interpretation` | Optional `"image_url"` for presenting complete stdout as an [image reference](content.md#image-url-references) once the command has finished |

Names must contain 1–32 Unicode code points and no ASCII control characters; spaces alone are not accepted.

Each start creates a fresh shell. Its directory and environment changes belong to that command; keep it running in an [input mode](#input-modes) to preserve state across calls. The command string follows the selected shell's syntax, while `cwd` is a literal path resolved before shell startup.

The inherited environment requests plain output with `NO_COLOR=1` and pagers set to `cat`. `TERM` is `dumb`, or `xterm-256color` in terminal mode. Login initialization can change the environment and working directory.

Host commands inherit the absolute path to `ivenna-report` in `IVENNA_REPORT` and the instance's data directory in `DATA_DIR`. Run `"$IVENNA_REPORT" --help` in the host shell for reporting commands and examples. See the [listener protocol](subscriptions.md).

## Input modes

| Mode | Input and output |
| --- | --- |
| `batch` | No live stdin; stdout and stderr have separate logs |
| `pipe` | Writable stdin until EOF is sent; stdout and stderr have separate logs |
| `terminal` | A pseudo-terminal for programs that require a terminal; stdout and stderr are merged into the stdout log |

For example, start an interactive Python process in a terminal and return immediately:

```json
{"name":"python","command":"python3 -u -i","mode":"terminal","yield_ms":0}
```

A terminal starts with 24 rows and 80 columns and can be resized. The tool returns its output stream without rendering a screen. Terminal processing can alter input and output bytes; use `batch` or `pipe` when bytes must be preserved. See the [runtime requirements](running.md#runtime-requirements) for terminal support.

## Continuing and controlling a command

Use the complete `command_id` returned by a yielded `run_host_shell` call or listed by `inspect_host_shell`. Commands are discoverable across activities, including while the starting activity is still waiting in `run_host_shell`. Input and control do not wait for another observation call's yield deadline.

Call `inspect_host_shell` with `{}` to inspect the default `shell`, startup `cwd`, and the first page of `commands`, or pass `{"command_id":"build-17"}` to select one. Entries include `command_id`, originating `focus_id`, `command_preview` (up to 160 UTF-8 bytes), `state`, `mode`, `stdin_open`, and `input_pending`.

The complete inspection reply fits 32 KiB. `offset` defaults to `0`; the result supplies that offset, `total_commands`, and `next_offset`. Pass a non-null `next_offset` as the next call's `offset` to read further entries. At the end, `next_offset` is `null`. An offset beyond the list returns no commands. An exact `command_id` filter applies before pagination. Pages follow the current registry order, which can change as commands retire.

Call `continue_host_shell` with the selected `command_id`. Omit `action` to read more output:

```json
{"command_id":"build-17","yield_ms":1000,"max_output_bytes":4096}
```

For a continuation, `yield_ms` waits for unread output or completion. It defaults to `1000` milliseconds; `0` inspects the current state, and values through `4294967295` are supported. The command keeps its existing execution deadline. `max_output_bytes` has the same range and default as `run_host_shell`.

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

Command observations contain state, elapsed time, full log paths, stream byte lengths, and bounded content. Nonzero exits, signals, execution timeouts, and an OS failure to start a command are ordinary outcomes.

| Result field | Meaning |
| --- | --- |
| `command_id` | Host command identity, returned for a handoff or continuation; usable as a handle only in its originating runtime while retained |
| `callback_id` | Reference for the completion observation arranged by the initial call |
| `state.running` | The command is still running |
| `state.finished` | The final outcome: `completed` with an exit code or other OS termination status, `timed_out`, or `not_started` with a reason |
| `state.unavailable` | The host could not establish a complete outcome; `reason` describes the failure |
| `elapsed_ms` | Monotonic elapsed time, fixed when Host observes the process outcome |
| `mode` | The selected `batch`, `pipe`, or `terminal` mode |
| `stdin` | Whether input is `open`, whether a write is `pending`, and an optional `error` |
| `stdout`, `stderr` | Full log `path` and snapshot `byte_length`, a `content` description, and a `range` for incremental observations |
| `output_error` | Present in handoff or completion callback results when output could not be read; observed status and log paths remain available |

A running pipe command can return:

```json
{
  "result": {
    "command_id": "build-17",
    "callback_id": "build-5",
    "state": {"running": {}},
    "elapsed_ms": 10002,
    "mode": "pipe",
    "stdin": {"open": true, "pending": false},
    "stdout": {
      "path": "/path/to/instance/data/host/2/example.stdout.log",
      "byte_length": 6,
      "range": {"offset": 0, "next_offset": 6},
      "content": {"text": {"text": "ready\n", "truncated": false}}
    },
    "stderr": {
      "path": "/path/to/instance/data/host/2/example.stderr.log",
      "byte_length": 0,
      "range": {"offset": 0, "next_offset": 0},
      "content": {"text": {"text": "", "truncated": false}}
    }
  }
}
```

Calls to `continue_host_shell` share one cursor per stream across activities. Each stream's `range` gives the byte `offset` before collection and `next_offset` afterward. Text reads return consecutive UTF-8 content; `truncated: true` means source bytes remain beyond the cursor. Each preview fits its share of the combined encoded budget and at most 2000 source lines. JSON escaping can reduce the text that fits.

The initial `run_host_shell` handoff has an independent prefix preview starting at byte `0`. It neither waits for another activity's output read nor advances the shared continuation cursors. A later continue call can therefore repeat output shown in that initial preview.

When `run_host_shell` returns the final result directly, it supplies a complete-source preview without `command_id` or incremental ranges, independently of output another activity may have read. A large text preview includes the source's beginning and end with an omitted-byte count. For example, exit code `7` appears as `"state":{"finished":{"completed":{"exited":7}}}`.

Completed stdout can return an image or complete file under the shared [content rules and limits](content.md). Native content is additional to the `max_output_bytes` text budget. Running output and stderr remain text or unavailable-content diagnostics. Use `batch` or `pipe` to preserve file bytes; for example:

```json
{"name":"report","command":"cat /path/to/report.pdf"}
```

To present complete stdout text as an image URL instead, set `interpretation: "image_url"`:

```json
{"name":"image-reference","command":"printf '%s' 'https://example.com/image.png'","interpretation":"image_url"}
```

After completion, `continue_host_shell` can return a retained command's complete native stdout once, independently of text already read. Earlier text-only observations do not prevent a later read from supplying the whole file when it encounters binary content. A native result or complete-source diagnostic has no stdout `range` and advances the shared cursor to the end. If the command has already finished at its initial handoff, that result can contain native media and a continuation can still return it.

A registered completion arrives as a [callback observation](input.md#focus-messages-and-callbacks). Its `source.host.command_id` identifies the command; the result in `text` omits the `command_id` field. This independent complete-source preview or diagnostic reports the host outcome; Ivenna assesses whether the assigned task succeeded. The callback does not advance continuation cursors or prevent a later native return. It carries media descriptions and log paths; `media_omission: "asynchronous_media_unavailable"` identifies native content that the text-only callback cannot carry.

For incremental `content.unavailable`, its `byte_length` describes the unsupported range; the stream's `byte_length` describes the entire log snapshot. Without a range, the diagnostic concerns the complete source. Full logs remain at the returned paths under `<DATA_DIR>/host/` independently of handle retention, and can be read through another command to inspect omitted text or media.

## Command lifetimes

Complete command references identify executions. Their numeric suffixes advance across restarts, while control handles remain available only in their originating runtime. Callback references connect the initial handoff with its later observation and remain retained across restart. A command handed off by its initial call remains owned by the host runtime and has one completion observation registered for its originating activity. That registration keeps the activity available across sleep until the observation is durably admitted. Reading or controlling the command from another activity does not redirect its completion. The `focus_id` in inspection records identifies where the command started.

Command state, handle retention, and the registered observation have separate lifetimes. Draining a handle does not cancel its completion observation; cancellation is unavailable. A response without tool calls lets the activity sleep while an observation remains registered. See [activity completion](attention.md#activity-completion) for the conditions under which it sleeps or ends.

`MAX_HOST_COMMANDS` limits live commands across all activities. Completion releases live capacity. A final result returned directly by `run_host_shell` retires its handle. Finished background handles remain available in a bounded cache for recent output collection; a continue call that drains one retires it, and older finished handles can be reclaimed for other commands. See [command lifecycle](architecture.md#command-lifecycle) for the cache limit. Full logs have a [separate retention lifecycle](running.md#host-output-and-deployment-files).

Shutdown stops commands and waits for cleanup. Batch and pipe cleanup covers the command's process group; terminal cleanup covers its original OS session, including background jobs in separate job-control groups. Shell backgrounding with `&` remains within this managed lifetime. Work that creates another OS session has an independent lifetime. If it holds the original terminal open, final output draining ends after one second with an unavailable-result diagnostic. The [architecture guide](architecture.md#processes-and-terminals) describes process ownership and cleanup.

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
| `input_busy` | A previous input write is still in flight |
| `control_failed` | A signal or terminal resize failed, with its diagnostic |
| `host_unavailable` | The host operation could not supply a complete result; effects may already have occurred |

`handoff_unavailable` returns `error` and `result` together. If output collection also fails, the result retains the observed state and log paths with an `output_error`. No completion observation was arranged for that failed handoff.

An initial preview read can instead fail after registration succeeds, returning `host_unavailable` with a result containing `command_id`, `callback_id`, observed status, log paths, and `output_error`. The returned callback ID confirms that the completion observation remains arranged.

These defined errors remain tool observations. Failures of task scheduling or runtime supervision follow the [runtime availability](design.md#runtime-availability) contract and end the runtime.
