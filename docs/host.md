# Host shell

Work sessions execute commands through the kernel's OS account and share its filesystem. Commands from different sessions can run concurrently.

The shell tools are defined in [tools.json](../packages/host/src/tools.json):

| Tool | Purpose |
| --- | --- |
| `get_host_shell` | Inspect the shell, default directory, and capability status |
| `run_host_shell` | Execute a command and return its outcome, output descriptions, and any stdout image |

## Shell description

Call `get_host_shell` with `{}` to inspect the shell and default working directory. For a kernel started in `/path/to/deployment`, the result is:

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

Command execution is available. The entries marked `planned` have no callable operations.

## Running commands

Call `run_host_shell` with a command string:

```json
{"command":"pwd","cwd":"/path/to/project"}
```

| Argument | Meaning |
| --- | --- |
| `command` | Required command in `/bin/sh` syntax; supports pipes, redirection, and heredocs |
| `cwd` | Working directory; absolute or relative to the kernel's startup directory, which is also the default |
| `timeout_ms` | Positive integer in milliseconds; defaults to `600000` (10 minutes) |
| `interpretation` | Optional `"image_url"` to present complete stdout text as an [image reference](content.md#image-url-references) |

Each call starts a fresh noninteractive `/bin/sh` with no terminal or live input. It inherits the kernel's startup environment and finds programs through its `PATH` or an explicit path; see [optional host tools](running.md#optional-host-tools). Changing `cwd` does not reload the environment. Shell variables and directory changes last for that call; filesystem changes persist.

The command environment sets `NO_COLOR=1`, `TERM=dumb`, and `PAGER`, `GIT_PAGER`, and `GH_PAGER` to `cat` for readable batch output. Processes remaining in the invocation's process group are stopped when the shell exits, times out, or is canceled. Background processes in that group end with the invocation; no later job-completion observation is supplied.

## Results and interruption

A command result is supplied as a text part containing JSON `result` with its outcome and both stream descriptions. Nonzero exits and timeouts are command outcomes. Image stdout adds a native image part alongside the description. An `error` with code `host_unavailable` means the invocation could not supply a complete command result. The [architecture guide](architecture.md#host-execution) describes the current failure boundary.

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
| `image` | An image description, with native content supplied separately |
| `unavailable` | `byte_length` and `reason` describing content that could not be supplied |

Stderr's `content` contains either a `text` preview or an `unavailable` diagnostic. See [tool content](content.md) for classification, image descriptions, preview bounds, and model-input limits. Content diagnostics leave the command outcome and stream descriptions available.

Each invocation creates distinct log files under `<DATA_DIR>/host/<session_id>/`. They contain the full streams, including output omitted from the reply, and outlive the working session. Later shell calls can read or remove them. See [data and retention](running.md#data-and-retention) for `DATA_DIR` configuration.

A timeout returns the captured output. Runtime cancellation stops the invocation without returning an ordinary tool result. Effects already produced remain in place in either case. See [startup and interruption](architecture.md#startup-and-interruption) for continuation after a runtime failure or restart.
