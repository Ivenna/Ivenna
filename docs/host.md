# Host shell

Work sessions execute commands through the kernel's OS account and share its filesystem. Commands from different sessions can run concurrently.

The shell tools are defined in [tools.json](../packages/host/src/tools.json):

| Tool | Purpose |
| --- | --- |
| `get_host_shell` | Inspect the shell and default directory |
| `run_host_shell` | Execute a command and return its outcome, output descriptions, and any stdout image |

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

Each call starts a fresh noninteractive `/bin/sh` with no terminal or live input, inheriting the kernel's startup environment.

The command environment sets `NO_COLOR=1`, `TERM=dumb`, and `PAGER`, `GIT_PAGER`, and `GH_PAGER` to `cat` for readable batch output. Processes remaining in the invocation's process group are stopped when the shell exits, times out, or is canceled. Background processes in that group end with the invocation; no later job-completion observation is supplied.

## Results and interruption

A command result is supplied as a text part containing JSON `result` with its outcome and both stream descriptions. Nonzero exits and timeouts are command outcomes. Image stdout adds a native image part alongside the description.

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

`run_host_shell` stores output in distinct log files under `<DATA_DIR>/host/<session_id>/`, creating missing directories when invoked. The files contain the full streams, including output omitted from the reply, and outlive the working session. Later shell calls can read or remove them. See [host output and deployment files](running.md#host-output-and-deployment-files) for `DATA_DIR` configuration and retention.

An invocation error returns JSON `error` with `code` and `message`:

| Code | Meaning |
| --- | --- |
| `invalid_arguments` | Arguments do not match the tool parameters; the command was not started |
| `host_unavailable` | The invocation could not supply a complete result; the host may already have changed |

The [architecture guide](architecture.md#host-execution) describes the current failure boundary.

A timeout returns the captured output. Runtime cancellation stops the invocation without returning an ordinary tool result. Effects already produced remain in place in either case. See [startup and interruption](architecture.md#startup-and-interruption) for continuation after a runtime failure or restart.
