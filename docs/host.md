# Host shell

Ivenna can inspect its deployment shell and execute commands. All sessions use the kernel's OS account and share its filesystem.

The assistant has two shell tools, defined in [tools.json](../packages/agent/src/tools.json):

| Tool | Purpose |
| --- | --- |
| `get_host_shell` | Inspect the shell, default directory, and capability status |
| `run_host_shell` | Execute a command and return a text summary or an image from stdout |

## Discovering the shell entry

Call `get_host_shell` with `{}`. For a service started in `/path/to/deployment`, the result is:

```json
{
  "result": {
    "shell": "/bin/sh",
    "cwd": "/path/to/deployment",
    "capabilities": {
      "command_execution": "available",
      "process_sessions": "planned",
      "stdin": "planned",
      "pty": "planned",
      "process_control": "planned",
      "background_jobs": "planned"
    }
  }
}
```

The current implementation executes individual commands. Capabilities marked `planned` reserve future process and terminal controls; they have no callable operations yet. See [host execution](architecture.md#host-execution) for their responsibilities and lifecycle.

## Running commands

Call `run_host_shell` with a command string:

```json
{"command":"pwd","cwd":"/path/to/project"}
```

| Argument | Meaning |
| --- | --- |
| `command` | Required command in `/bin/sh` syntax; supports pipes, redirection, and heredocs |
| `cwd` | Working directory; absolute or relative to the service's startup directory, which is also the default |
| `timeout_ms` | Positive integer in milliseconds; defaults to `600000` (10 minutes) |
| `expected` | Optional expectation for stdout; see [expected content](content.md#expected-content) for the object branches and defaults |

Each call starts a separate noninteractive shell with no terminal or live input. It inherits the service's startup environment, which remains the same when `cwd` changes. Changes to shell variables and the current directory last for that call; filesystem changes persist. Programs can be invoked by path or found through the service's `PATH`; see [optional host tools](running.md#optional-host-tools).

Commands from separate conversations can run concurrently against the same files. A prior read describes the file at that time; another session may change it before a later command.

The command environment sets `NO_COLOR=1`, `TERM=dumb`, and `PAGER`, `GIT_PAGER`, and `GH_PAGER` to `cat` for readable batch output. Processes remaining in the invocation's process group are stopped when the shell exits, times out, or is canceled. A shell background job does not provide persistent job control or later completion input to the model; those capabilities remain planned.

## Results and interruption

An image from stdout is returned directly when the command exits with code `0`; that reply carries no stderr or log paths. Other command results use a JSON `result` containing the outcome and both output stream descriptions. Nonzero exits and timeouts remain command results. If the tool cannot return a command result, it returns `error` with `code` and `message`.

For session `1` with the default data directory, the `pwd` command above returns a text summary such as:

```json
{
  "result": {
    "outcome": {"completed": {"exited": 0}},
    "stdout": {
      "path": "/path/to/deployment/.ivenna/host/1/command.stdout.log",
      "content": {"text": {"text": "/path/to/project\n", "truncated": false}}
    },
    "stderr": {
      "path": "/path/to/deployment/.ivenna/host/1/command.stderr.log",
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

In a text summary, both `stdout` and `stderr` contain an absolute `path` to the complete output file. Stdout's `content` object contains exactly one branch:

| Content branch | Meaning |
| --- | --- |
| `text` | A UTF-8 preview in `text`, with `truncated` indicating omitted content |
| `image` | Image metadata: either `data` with `format` and `byte_length`, or `url` with an empty object |
| `unavailable` | `byte_length` and `reason` describing content that could not be supplied |

Stderr's `content` contains either a `text` preview or an `unavailable` diagnostic. Content diagnostics do not change the command outcome. Model input limits can also replace a returned image with a `content_limit` error after the command has executed. See [tool content](content.md) for classification, preview bounds, image handling, and request limits.

Full stdout and stderr remain in files under `<DATA_DIR>/host/<session_id>/`, including output omitted from the reply. Each invocation creates distinct log files, which remain after the conversation is archived. Subsequent shell calls can read or remove them. `DATA_DIR` defaults to `.ivenna` in the startup directory; see [local data](running.md#local-data) for configuration.

A timeout returns a summary of the output captured so far. Completed command effects remain after a timeout or kernel cancellation. Restarting does not restore the old runtime transcript. Inspect an interrupted command's effects before deciding whether to run it again; see [startup and interruption](architecture.md#startup-and-interruption).
