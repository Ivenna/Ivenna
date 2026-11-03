# Host shell

Ivenna can inspect its deployment shell and execute commands. The shell provides access to the programs and files available to the service account.

The assistant has two host tools, defined in [tools.json](../packages/agent/src/tools.json):

| Tool | Purpose |
| --- | --- |
| `get_host_shell` | Inspect the shell, default directory, and capability status |
| `run_host_shell` | Execute a command and return its outcome, output previews, and log paths |

Tool replies contain either `result` or `error`. An error contains `code` and `message`.

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

The current implementation executes individual commands. Capabilities marked `planned` reserve future process and terminal controls; they have no callable operations yet. See [planned process control](architecture.md#planned-process-control) for their responsibilities and lifecycle.

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

Each call starts a separate noninteractive shell with no terminal or live input. It inherits the service's startup environment, which remains the same when `cwd` changes. Changes to shell variables and the current directory last for that call; filesystem changes persist. Programs can be invoked by path or found through the service's `PATH`; see [optional host tools](running.md#optional-host-tools).

Commands run as the service's OS account. All sessions share that account and filesystem. The command environment sets `NO_COLOR=1`, `TERM=dumb`, and `PAGER`, `GIT_PAGER`, and `GH_PAGER` to `cat` for readable batch output. Processes remaining in the invocation's process group are stopped when the shell exits, times out, or is canceled.

## Results and interruption

A command result contains its outcome and both output streams. For session `1`, the command above returns a result such as:

```json
{
  "result": {
    "outcome": {"completed": {"exited": 0}},
    "stdout": {
      "text": "/path/to/project\n",
      "truncated": false,
      "path": "/path/to/deployment/.ivenna/host/1/command.stdout.log"
    },
    "stderr": {
      "text": "",
      "truncated": false,
      "path": "/path/to/deployment/.ivenna/host/1/command.stderr.log"
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

A nonzero exit code remains a command result. Completed outcomes can also report `stopped` with a signal or `unknown` with a numeric status.

Both `stdout` and `stderr` contain:

| Field | Meaning |
| --- | --- |
| `text` | A UTF-8 preview of at most 16 KiB, retaining the beginning and end when truncated |
| `truncated` | Whether the preview omitted content |
| `path` | Absolute path to the complete output file |

The preview limit does not stop the command. Invalid UTF-8 bytes are replaced in previews; log files retain the original bytes. Logs remain under `.ivenna/host/<session_id>/` in the startup directory and can be read or removed through subsequent shell calls.

A timeout returns the output captured so far. Service cancellation also stops the process group. Neither action undoes completed changes. A restart may repeat a command whose result was not checkpointed; see [failure and recovery](architecture.md#failure-and-recovery).
