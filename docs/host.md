# Host shell

The [host tools](../packages/host/src/tools.json) run shell code through the kernel's OS account on the shared host filesystem. They are available to activity sessions. A command has its own lifetime: its handle connects later observations and interactions to the same running process.

| Tool | Purpose |
| --- | --- |
| `get_host_shell` | Inspect the default shell, startup directory, and retained command handles |
| `run_host_shell` | Start a command and wait for completion or the call's yield deadline |
| `continue_host_shell` | Read further output, supply input, send a signal, or resize a terminal |

## Starting a command

Call `run_host_shell` with a command string:

```json
{"command":"make -j4","cwd":"/path/to/project","yield_ms":1000}
```

| Argument | Meaning |
| --- | --- |
| `command` | Required command text, interpreted by the selected shell |
| `cwd` | Working directory, absolute or relative to the kernel's startup directory; defaults to that startup directory |
| `shell` | Shell executable accepting `-c`; defaults to `/bin/sh` |
| `login` | Use `-lc` for the selected shell's login initialization; defaults to `false` |
| `mode` | `batch` (default), `pipe`, or `terminal`; see [input modes](#input-modes) |
| `yield_ms` | How long this call waits, from `0` through `30000` milliseconds; defaults to `1000` |
| `timeout_ms` | Optional positive execution deadline in milliseconds, up to `4294967295`; omitted means no execution deadline |
| `max_output_bytes` | Combined encoded stdout/stderr preview budget, from `512` through `16384` bytes; defaults to `16384`; result metadata and log paths are additional |
| `interpretation` | Optional `"image_url"` for presenting complete stdout as an [image reference](content.md#image-url-references) once the command has finished |

`yield_ms` bounds this call's wait for completion; it does not stop execution. A command still running when the call yields returns a `command_id` for subsequent interaction and [completion delivery](#commands-that-outlive-a-call). `timeout_ms` bounds execution independently of these calls.

Each start creates a fresh shell. Its directory and environment changes belong to that command; keep it running in an [input mode](#input-modes) to preserve state across calls. The command string follows the selected shell's syntax, while `cwd` is a literal path resolved before shell startup.

The inherited environment requests plain output with `NO_COLOR=1` and pagers set to `cat`. `TERM` is `dumb`, or `xterm-256color` in terminal mode. Login initialization can change the environment and working directory.

## Input modes

| Mode | Input and output |
| --- | --- |
| `batch` | No live stdin; stdout and stderr have separate logs |
| `pipe` | Writable stdin until EOF is sent; stdout and stderr have separate logs |
| `terminal` | A pseudo-terminal for programs that require a terminal; stdout and stderr are merged into the stdout log |

Choose the input mode for the program's I/O protocol. For example, start a terminal REPL:

```json
{"command":"python3 -u -i","mode":"terminal","yield_ms":1000}
```

A terminal starts with 24 rows and 80 columns and can be resized. The tool returns its output stream without rendering a screen. Terminal processing can alter input and output bytes; use `batch` or `pipe` when bytes must be preserved. See the [runtime requirements](running.md#runtime-requirements) for terminal support.

## Continuing and controlling a command

Call `continue_host_shell` with a `command_id`. Omit `action` to read more output:

```json
{"command_id":17,"yield_ms":1000,"max_output_bytes":4096}
```

The wait and output-budget arguments have the same ranges and defaults as `run_host_shell`. A continue call waits for unread output, completion, or its yield deadline; `yield_ms: 0` takes an immediate snapshot.

The optional `action` selects exactly one operation:

| Action | Example | Effect |
| --- | --- | --- |
| Read | `{"read":{}}` | Observe output and status without supplying input |
| Write | `{"write":{"text":"print(1 + 1)\n"}}` | Supply text to a pipe or terminal |
| Signal | `{"signal":{"name":"interrupt"}}` | Send `interrupt` (SIGINT), `terminate` (SIGTERM), or `kill` (SIGKILL) |
| Resize | `{"resize":{"rows":40,"cols":120}}` | Change dimensions in terminal mode |

`eof: true` in `action.write` closes pipe stdin after the supplied text; later writes cannot reopen it. In terminal mode it sends Ctrl-D and leaves the transport writable.

Each write accepts at most 16384 UTF-8 bytes and proceeds independently of the observation call. `stdin.pending` identifies a write still in flight; another write returns `input_busy` until it finishes. An optional `stdin.error` reports a failed or canceled write. Some input may already have reached the program when an error occurs; inspect its response before repeating that input.

Interrupt targets the terminal's foreground group, or the command's process group without a terminal. Terminate and kill cover the original terminal session or command group. A program can handle or ignore SIGINT and SIGTERM; SIGKILL forces termination. Output remains available for collection afterward.

Activities share command handles. Input and control do not wait for another observation call's yield deadline.

## Output and results

Command observations contain state, elapsed time, full log paths, stream byte lengths, and bounded content. Nonzero exits, signals, execution timeouts, and an OS failure to start a command are ordinary outcomes.

| Result field | Meaning |
| --- | --- |
| `command_id` | Present for a retained command; use it in continue and inspection calls |
| `state.running` | The command is still running |
| `state.finished` | The final outcome: `completed` with an exit code or other OS termination status, `timed_out`, or `not_started` with a reason |
| `state.unavailable` | The host could not establish a complete outcome; `reason` describes the failure |
| `elapsed_ms` | Monotonic elapsed time through execution and cleanup, fixed after completion |
| `mode` | The selected `batch`, `pipe`, or `terminal` mode |
| `stdin` | Whether input is `open`, whether a write is `pending`, and an optional `error` |
| `stdout`, `stderr` | Full log `path` and snapshot `byte_length`, a `content` description, and a `range` for incremental observations |
| `media_omission` | A callback's `"asynchronous_media_unavailable"` marker when it describes an image without a native image part |

A running pipe command can return:

```json
{
  "result": {
    "command_id": 17,
    "state": {"running": {}},
    "elapsed_ms": 1002,
    "mode": "pipe",
    "stdin": {"open": true, "pending": false},
    "stdout": {
      "path": "/path/to/deployment/.ivenna/host/2/example.stdout.log",
      "byte_length": 6,
      "range": {"offset": 0, "next_offset": 6},
      "content": {"text": {"text": "ready\n", "truncated": false}}
    },
    "stderr": {
      "path": "/path/to/deployment/.ivenna/host/2/example.stderr.log",
      "byte_length": 0,
      "range": {"offset": 0, "next_offset": 0},
      "content": {"text": {"text": "", "truncated": false}}
    }
  }
}
```

Each stream has one cursor shared by the initial reply, continue calls, and completion delivery. Its `range` gives the byte `offset` before collection and `next_offset` afterward. Text reads return consecutive UTF-8 content; `truncated: true` means source bytes remain beyond the cursor. Each preview fits its share of the combined encoded budget and at most 2000 source lines. JSON escaping can reduce the text that fits.

A command completed within its initial call returns a complete-source preview without `command_id` or incremental ranges. A large text preview includes the source's beginning and end with an omitted-byte count. For example, exit code `7` appears as `"state":{"finished":{"completed":{"exited":7}}}`.

Final complete stdout can supply an image or image URL reference through [content classification](content.md). This result has no `range` and advances stdout to its end. Callbacks describe media with `media_omission: "asynchronous_media_unavailable"`; a tool call can still collect the complete native image or URL once while the finished handle remains available. Running output remains text or an unavailable-content diagnostic.

For incremental `content.unavailable`, its `byte_length` describes the unsupported range; the stream's `byte_length` describes the entire log snapshot. Without a range, the diagnostic concerns the complete source. Full logs remain under `<DATA_DIR>/host/<originating session_id>/` independently of handle retention, and can be read through another command to inspect omitted text or media.

## Commands that outlive a call

When a command outlives its initial call, the runtime registers a durable completion callback whose ID becomes `command_id`. The session can continue other work or wait. Completion returns to the originating session as `source: host`, using the [result format and output cursor](#output-and-results) described above. Another activity's interaction does not redirect it. A command completed within its initial call creates no callback.

Call `get_host_shell` with `{}` to inspect the default `shell`, startup `cwd`, and retained `commands`, or pass `{"command_id":17}` to select one. Entries include `command_id`, originating `session_id`, `command_preview` (up to 160 UTF-8 bytes), `state`, `mode`, `stdin_open`, and `input_pending`. The list has a 32 KiB encoded reply budget; `total_commands` and `commands_truncated` identify omitted entries. Pending host callback IDs in the session's current-state snapshot also identify its commands after compaction.

`MAX_HOST_COMMANDS` limits live commands across all activities. Completion releases live capacity. Up to the same count of finished handles remains available for output collection; draining a handle retires it, and older finished handles can be reclaimed for other commands. Full logs have a [separate retention lifecycle](running.md#host-output-and-deployment-files).

Shutdown stops and joins commands. Batch and pipe cleanup covers the command's process group; terminal cleanup covers its original OS session, including background jobs in separate job-control groups. Shell backgrounding with `&` remains within this managed lifetime. A program that explicitly creates another OS session, for example with `setsid`, gives that work an independent lifetime. If it holds the original terminal open, final output draining ends after one second with an unavailable-result diagnostic.

After restart, stored completions remain available and unfinished registrations receive an observation of interruption with unknown effects. Host processes and handles are not restored, and commands are not replayed. Inspect uncertain effects before repeating work. See [startup and interruption](architecture.md#startup-and-interruption).

## Errors

Errors describe the failed operation without erasing effects already produced. In particular, `handoff_unavailable` means a started command could not acquire a completion callback and has been stopped and joined. The reply includes both `error` and the command `result`, preserving its outcome and captured content.

Defined tool errors include:

| Code | Meaning |
| --- | --- |
| `invalid_arguments` | The invocation does not match the tool's arguments |
| `commands_unavailable` | No live-command slot is available; the command was not started |
| `handoff_unavailable` | The command started but could not acquire a completion callback; it was stopped and its observation is retained |
| `unknown_command` | The handle is unknown or was retired, including after restart; full logs and stored callbacks have separate lifetimes |
| `command_finished` | An input or control action targeted a finished command; read its remaining output instead |
| `stdin_closed` | The command has no writable input, including batch mode and a pipe after EOF |
| `input_busy` | A previous input write is still in flight |
| `control_failed` | A signal or terminal resize failed, with its diagnostic |
| `host_unavailable` | The host operation could not supply a complete result; effects may already have occurred |

These defined errors remain tool observations. Failures to persist callback registration or publish completion follow the [runtime availability](design.md#runtime-availability) contract and end the runtime.
