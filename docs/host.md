# Host shell

The [host tools](../packages/host/src/tools.json) run shell code through the kernel's OS account on the shared host filesystem. They are available to activity sessions. A command has its own host identity so activities can discover and control it while it runs.

| Tool | Purpose |
| --- | --- |
| `get_host_shell` | Inspect shell defaults and discover command handles |
| `run_host_shell` | Run a command, waiting for completion unless a wait duration is supplied |
| `continue_host_shell` | Read output, supply input, send a signal, or resize a terminal |

## Running a command

Call `run_host_shell` to wait for a command:

```json
{"command":"make -j4","cwd":"/path/to/project"}
```

By default, the call waits through execution and cleanup and returns the final outcome with a complete-source output preview. It keeps the activity's activation and context in place while the core and other activities continue. New observations enter that activity after the complete model/tool round.

Supply `yield_ms` to limit this call's wait for completion. A command still running at that boundary returns a `command_id` for further interaction through `continue_host_shell`.

| Argument | Meaning |
| --- | --- |
| `command` | Required command text, interpreted by the selected shell |
| `cwd` | Working directory, absolute or relative to the kernel's startup directory; defaults to that startup directory |
| `shell` | Shell executable accepting `-c`; defaults to `/bin/sh` |
| `login` | Use `-lc` for the selected shell's login initialization; defaults to `false` |
| `mode` | `batch` (default), `pipe`, or `terminal`; see [input modes](#input-modes) |
| `yield_ms` | Optional wait duration in milliseconds, from `0` through `4294967295`; omitted means wait for completion; `0` observes immediately |
| `timeout_ms` | Optional positive execution deadline in milliseconds, up to `4294967295`; omitted means no execution deadline |
| `max_output_bytes` | Combined encoded stdout/stderr preview budget, from `512` through `16384` bytes; defaults to `16384`; result metadata and log paths are additional |
| `interpretation` | Optional `"image_url"` for presenting complete stdout as an [image reference](content.md#image-url-references) once the command has finished |

Each start creates a fresh shell. Its directory and environment changes belong to that command; keep it running in an [input mode](#input-modes) to preserve state across calls. The command string follows the selected shell's syntax, while `cwd` is a literal path resolved before shell startup.

The inherited environment requests plain output with `NO_COLOR=1` and pagers set to `cat`. `TERM` is `dumb`, or `xterm-256color` in terminal mode. Login initialization can change the environment and working directory.

## Input modes

| Mode | Input and output |
| --- | --- |
| `batch` | No live stdin; stdout and stderr have separate logs |
| `pipe` | Writable stdin until EOF is sent; stdout and stderr have separate logs |
| `terminal` | A pseudo-terminal for programs that require a terminal; stdout and stderr are merged into the stdout log |

Choose the input mode for the program's I/O protocol. For example, call `run_host_shell` with an immediate observation to retain a terminal REPL:

```json
{"command":"python3 -u -i","mode":"terminal","yield_ms":0}
```

A terminal starts with 24 rows and 80 columns and can be resized. The tool returns its output stream without rendering a screen. Terminal processing can alter input and output bytes; use `batch` or `pipe` when bytes must be preserved. See the [runtime requirements](running.md#runtime-requirements) for terminal support.

## Continuing and controlling a command

Use a `command_id` returned by a yielded `run_host_shell` call or listed by `get_host_shell`. Commands are discoverable across activities, including while the starting activity is still waiting in `run_host_shell`. Input and control do not wait for another observation call's yield deadline.

Call `get_host_shell` with `{}` to inspect the default `shell`, startup `cwd`, and `commands`, or pass `{"command_id":17}` to select one. Entries include `command_id`, originating `session_id`, `command_preview` (up to 160 UTF-8 bytes), `state`, `mode`, `stdin_open`, and `input_pending`. The list has a 32 KiB encoded reply budget; `total_commands` and `commands_truncated` identify omitted entries.

Call `continue_host_shell` with the selected `command_id`. Omit `action` to read more output:

```json
{"command_id":17,"yield_ms":1000,"max_output_bytes":4096}
```

`yield_ms` waits for unread output or completion, up to `4294967295` milliseconds; it defaults to `1000`, and `0` takes an immediate snapshot. It controls only this observation's wait. The command's optional execution deadline remains independent. `max_output_bytes` has the same range and default as `run_host_shell`.

The optional `action` selects exactly one operation:

| Action | Example | Effect |
| --- | --- | --- |
| Read | `{"read":{}}` | Observe output and status without supplying input |
| Write | `{"write":{"text":"print(1 + 1)\n"}}` | Supply text to a pipe or terminal; optional `eof` ends input after that text |
| Signal | `{"signal":{"name":"interrupt"}}` | Send `interrupt` (SIGINT), `terminate` (SIGTERM), or `kill` (SIGKILL) |
| Resize | `{"resize":{"rows":40,"cols":120}}` | Change dimensions in terminal mode |

`eof: true` in `action.write` closes pipe stdin after the supplied text; later writes cannot reopen it. In terminal mode it sends Ctrl-D and leaves the transport writable.

Each write accepts at most 16384 UTF-8 bytes and proceeds independently of the observation call. `stdin.pending` identifies a write still in flight; another write returns `input_busy` until it finishes. An optional `stdin.error` reports a failed or canceled write. Some input may already have reached the program when an error occurs; inspect its response before repeating that input.

Interrupt targets the terminal's foreground group, or the command's process group without a terminal. Terminate and kill cover the original terminal session or command group. A program can handle or ignore SIGINT and SIGTERM; SIGKILL forces termination. Output remains available for collection afterward.

## Output and results

Command observations contain state, elapsed time, full log paths, stream byte lengths, and bounded content. Nonzero exits, signals, execution timeouts, and an OS failure to start a command are ordinary outcomes.

| Result field | Meaning |
| --- | --- |
| `command_id` | Present in incremental observations; use it while the handle remains available |
| `state.running` | The command is still running |
| `state.finished` | The final outcome: `completed` with an exit code or other OS termination status, `timed_out`, or `not_started` with a reason |
| `state.unavailable` | The host could not establish a complete outcome; `reason` describes the failure |
| `elapsed_ms` | Monotonic elapsed time through execution and cleanup, fixed after completion |
| `mode` | The selected `batch`, `pipe`, or `terminal` mode |
| `stdin` | Whether input is `open`, whether a write is `pending`, and an optional `error` |
| `stdout`, `stderr` | Full log `path` and snapshot `byte_length`, a `content` description, and a `range` for incremental observations |

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

Incremental observations share one cursor per stream across activities. Each stream's `range` gives the byte `offset` before collection and `next_offset` afterward. Text reads return consecutive UTF-8 content; `truncated: true` means source bytes remain beyond the cursor. Each preview fits its share of the combined encoded budget and at most 2000 source lines. JSON escaping can reduce the text that fits.

When `run_host_shell` returns the final result directly, it supplies a complete-source preview without `command_id` or incremental ranges, independently of output another activity may have read. A large text preview includes the source's beginning and end with an omitted-byte count. For example, exit code `7` appears as `"state":{"finished":{"completed":{"exited":7}}}`.

Final complete stdout can supply an image or image URL reference through [content classification](content.md). The first final observation of a retained handle can supply its complete native media once, independently of the text cursor. This stdout description has no `range` and advances its cursor to the end. Running output remains text or an unavailable-content diagnostic.

For incremental `content.unavailable`, its `byte_length` describes the unsupported range; the stream's `byte_length` describes the entire log snapshot. Without a range, the diagnostic concerns the complete source. Full logs remain under `<DATA_DIR>/host/<originating session_id>/` independently of handle retention, and can be read through another command to inspect omitted text or media.

## Command lifetimes

Command IDs identify commands within the current runtime. A command returned while running remains owned by the host runtime even if its starting activity ends. Completion does not produce an event or keep a session alive. The `session_id` in inspection records identifies where the command started.

`MAX_HOST_COMMANDS` limits live commands across all activities. Completion releases live capacity. A final result returned directly by `run_host_shell` retires its handle. Up to the same configured count of finished retained handles remains available for output collection; a continue call that drains one retires it, and older finished handles can be reclaimed for other commands. Full logs have a [separate retention lifecycle](running.md#host-output-and-deployment-files).

Shutdown stops and joins commands. Batch and pipe cleanup covers the command's process group; terminal cleanup covers its original OS session, including background jobs in separate job-control groups. Shell backgrounding with `&` remains within this managed lifetime. A program that explicitly creates another OS session, for example with `setsid`, gives that work an independent lifetime. If it holds the original terminal open, final output draining ends after one second with an unavailable-result diagnostic.

Host processes and handles are not restored after restart, and commands are not replayed. Saved working history retains only confirmed exchanges. An interrupted call may have produced effects without a saved outcome; inspect uncertain effects before repeating work. See [startup and interruption](architecture.md#startup-and-interruption).

## Errors

Errors describe the failed operation without erasing effects already produced. Defined tool errors include:

| Code | Meaning |
| --- | --- |
| `invalid_arguments` | The invocation does not match the tool's arguments |
| `commands_unavailable` | No live-command slot is available; the command was not started |
| `unknown_command` | The handle is unknown or was retired; full logs have a separate lifetime |
| `command_finished` | An input or control action targeted a finished command; read its remaining output instead |
| `stdin_closed` | The command has no writable input, including batch mode and a pipe after EOF |
| `input_busy` | A previous input write is still in flight |
| `control_failed` | A signal or terminal resize failed, with its diagnostic |
| `host_unavailable` | The host operation could not supply a complete result; effects may already have occurred |

These defined errors remain tool observations. Failures of task scheduling or runtime supervision follow the [runtime availability](design.md#runtime-availability) contract and end the runtime.
