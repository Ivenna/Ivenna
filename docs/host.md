# Host shell

The [shell tools](../packages/host/src/tools.json) are available only to activity sessions. Commands run through the kernel's OS account on its shared filesystem and can execute concurrently across sessions.

| Tool | Purpose |
| --- | --- |
| `get_host_shell` | Inspect the shell and default directory |
| `run_host_shell` | Execute synchronously, or start a background command whose completion returns to this session |

## Shell description

Call `get_host_shell` with `{}` to inspect the shell and default working directory. For a kernel started in `/path/to/deployment`, the result is:

```json
{
  "result": {
    "shell": "/bin/sh",
    "cwd": "/path/to/deployment"
  }
}
```

## Running commands

Call `run_host_shell` with a command string:

```json
{"command":"pwd","cwd":"/path/to/project"}
```

| Argument | Meaning |
| --- | --- |
| `command` | Required command in `/bin/sh` syntax |
| `cwd` | Working directory; absolute or relative to the kernel's startup directory, which is also the default |
| `timeout_ms` | Integer from `1` through `4294967295` in milliseconds; defaults to `600000` (10 minutes) |
| `interpretation` | Optional `"image_url"` to present complete stdout text as an [image reference](content.md#image-url-references) |
| `background` | Optional boolean, default `false`; return `activity_id` while the command runs independently of this activation |

Each call starts a fresh noninteractive `/bin/sh` with no terminal or live input, inheriting the kernel's startup environment.

The command environment sets `NO_COLOR=1`, `TERM=dumb`, and `PAGER`, `GIT_PAGER`, and `GH_PAGER` to `cat` for readable batch output. Processes remaining in the invocation's process group are stopped when the shell exits, times out, or is canceled. Use the tool's `background` argument to receive completion later; shell backgrounding with `&` remains subject to the invocation's process-group lifetime.

## Results and interruption

A synchronous command result is supplied as a text part containing JSON `result` with its outcome and both stream descriptions. Nonzero exits and timeouts are command outcomes. Image stdout adds a native image part alongside the description.

For session `2` with the default data directory, the `pwd` command above returns a text summary such as:

```json
{
  "result": {
    "outcome": {"completed": {"exited": 0}},
    "stdout": {
      "path": "/path/to/deployment/.ivenna/host/2/5a3cd1c04b1a4b1197b611f97c7032de.stdout.log",
      "content": {"text": {"text": "/path/to/project\n", "truncated": false}}
    },
    "stderr": {
      "path": "/path/to/deployment/.ivenna/host/2/5a3cd1c04b1a4b1197b611f97c7032de.stderr.log",
      "content": {"text": {"text": "", "truncated": false}}
    }
  }
}
```

`outcome` contains exactly one branch:

| Outcome | Meaning |
| --- | --- |
| `{"completed":{"exited":0}}` | The command exited; the payload is its exit code |
| `{"completed":{"signal":"TERM"}}` | The process was terminated by a signal; known signals use names |
| `{"timed_out":{}}` | The timeout was reached and the process group was stopped |

Completed outcomes can also report `stopped` with a signal or `unknown` with a numeric status.

In the result description, both `stdout` and `stderr` contain an absolute `path` to the complete output file. Stdout's `content` object contains exactly one branch:

| Content branch | Meaning |
| --- | --- |
| `text` | A UTF-8 preview in `text`, with `truncated` indicating omitted content |
| `image` | An image description; synchronous results supply the native image separately |
| `unavailable` | `byte_length` and `reason` describing content that could not be supplied |

Stderr's `content` contains either a `text` preview or an `unavailable` diagnostic. See [tool content](content.md) for classification, image descriptions, preview bounds, and model-input limits. Content diagnostics leave the command outcome and stream descriptions available.

`run_host_shell` creates distinct full-stream logs under `<DATA_DIR>/host/<session_id>/`. They survive session sleep and context unloading; later shell calls can read or remove them. See [host artifact retention](running.md#host-output-and-deployment-files).

Defined tool errors return JSON `error` with `code` and `message`:

| Code | Meaning |
| --- | --- |
| `invalid_arguments` | Arguments do not match the tool parameters; the command was not started |
| `background_unavailable` | No background execution slot or callback registration is available; the command was not started |
| `host_unavailable` | The invocation could not supply a complete result; the host may already have changed |

The [architecture guide](architecture.md#host-execution) describes the current failure boundary.

A synchronous timeout returns the captured output; a background timeout returns through its completion callback. Runtime cancellation stops and joins the invocation. Effects already produced remain in place in either case. See [startup and interruption](architecture.md#startup-and-interruption) for continuation after a runtime failure or restart.

## Background commands

Set `background: true` to receive the command's callback ID in `activity_id` while it runs independently of the activation:

```json
{"result":{"running":{"activity_id":1}}}
```

Completion returns to the invoking session as a `source: host` callback whose `id` matches the returned `activity_id`. The session can continue or sleep while waiting; delivery and scheduling follow [callback mail](communication.md#callback-mail).

On completion, the callback's `text` contains the JSON `result` described [above](#results-and-interruption), including outcome, both stream descriptions, and full log paths. For image stdout, the text also includes `"media_omission":"asynchronous_media_unavailable"`; no native image accompanies the callback. Use synchronous execution when the model needs the image itself. A failure to obtain a complete command result can instead produce a JSON `host_unavailable` error description.

`MAX_BACKGROUND_COMMANDS` bounds running tasks; registrations use the session's `MAX_PENDING_CALLBACKS` allowance. Shutdown cancels and joins commands. After restart, stored completions remain available; unfinished registrations instead receive a plain-text notice of unknown interrupted effects. Commands are not replayed, so inspect uncertain effects before repeating work.
