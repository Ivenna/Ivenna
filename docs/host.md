# Host shell

Work sessions can inspect Ivenna's deployment shell and execute commands. They use the kernel's OS account and share its filesystem.

The shell tools are defined in [tools.json](../packages/agent/src/tools.json):

| Tool | Purpose |
| --- | --- |
| `get_host_shell` | Inspect the shell, default directory, and capability status |
| `run_host_shell` | Execute a command and return its outcome, output descriptions, and any stdout image |

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
| `interpretation` | Optional `"image_url"` to present complete stdout text as an [image reference](content.md#image-url-references) |

Each call starts a separate noninteractive shell with no terminal or live input. It inherits the service's startup environment, which remains the same when `cwd` changes. Changes to shell variables and the current directory last for that call; filesystem changes persist. Programs can be invoked by path or found through the service's `PATH`; see [optional host tools](running.md#optional-host-tools).

Commands from separate sessions can run concurrently against the same files. A prior read describes the file at that time; another session may change it before a later command.

The command environment sets `NO_COLOR=1`, `TERM=dumb`, and `PAGER`, `GIT_PAGER`, and `GH_PAGER` to `cat` for readable batch output. Processes remaining in the invocation's process group are stopped when the shell exits, times out, or is canceled. A shell background job does not provide persistent job control or later completion input to the model; those capabilities remain planned.

## Results and interruption

Every command result includes a text part containing a JSON `result` with the outcome and both output stream descriptions. Image stdout adds a native image part alongside that description, including when the command exits with a nonzero code or times out. Nonzero exits and timeouts remain command results. If the tool cannot return a command result, it returns a text `error` with `code` and `message`.

For session `2` with the default data directory, the `pwd` command above returns a text summary such as:

```json
{
  "result": {
    "outcome": {"completed": {"exited": 0}},
    "stdout": {
      "path": "/path/to/deployment/.ivenna/host/2/command.stdout.log",
      "content": {"text": {"text": "/path/to/project\n", "truncated": false}}
    },
    "stderr": {
      "path": "/path/to/deployment/.ivenna/host/2/command.stderr.log",
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

Full stdout and stderr remain in files under `<DATA_DIR>/host/<session_id>/`, including output omitted from the reply. Each invocation creates distinct log files that outlive the working session; their retention is independent of mail folders and flags. Subsequent shell calls can read or remove them. `DATA_DIR` defaults to `.ivenna` in the startup directory; see [local data](running.md#local-data) for configuration.

A timeout returns a summary of the output captured so far. Completed command effects remain after a timeout or kernel cancellation. Restarting does not restore the old runtime transcript. Inspect an interrupted command's effects before deciding whether to run it again; see [startup and interruption](architecture.md#startup-and-interruption).
