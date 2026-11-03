# Host shell and recommended tools

Ivenna can inspect its deployment shell, execute commands, and discover recommended command-line tools. Follow the [running guide](running.md) to install the declared tools and [prepare Codex](running.md#preparing-codex) before delegating work to it.

The assistant has three host tools, defined in [tools.json](../packages/agent/src/tools.json):

| Tool | Purpose |
| --- | --- |
| `get_host_shell` | Inspect the shell, default directory, and capability status |
| `get_recommended_tools` | Read the complete recommendation catalog |
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

## Discovering recommendations

Call `get_recommended_tools` with `{}` to read all recommendations at once. The result contains a `tools` list; each entry provides a name, command, description, and help entry point:

```json
{
  "result": {
    "tools": [
      {
        "name": "codex",
        "command": "codex",
        "description": "A coding agent for investigating and implementing tasks in a project.",
        "help": "Run codex --help to discover its capabilities; inspect codex exec --help for non-interactive use."
      }
    ]
  }
}
```

Codex is currently the only recommendation. Consult its own help for detailed options. Running bare `codex` starts the interactive interface, while `exec` supports noninteractive delegation; see the [official CLI reference](https://learn.chatgpt.com/docs/cli/reference).

## Running commands

Call `run_host_shell` with a command string:

```json
{"command":"codex --version","cwd":"/path/to/project"}
```

| Argument | Meaning |
| --- | --- |
| `command` | Required command in `/bin/sh` syntax; supports pipes, redirection, and heredocs |
| `cwd` | Working directory; absolute or relative to the service's startup directory, which is also the default |
| `timeout_ms` | Positive integer in milliseconds; defaults to `600000` (10 minutes) |

The prepared tool environment stays active when `cwd` changes. Each call starts a separate noninteractive shell with no terminal or live input. Changes to shell variables and the current directory last for that call; filesystem changes persist.

Commands run as the service's OS account with its inherited environment. All sessions share that account and filesystem. The command environment sets `NO_COLOR=1`, `TERM=dumb`, and `PAGER`, `GIT_PAGER`, and `GH_PAGER` to `cat` for readable batch output. Run foreground commands: remaining processes in the invocation's process group are stopped when the call ends.

## Results and interruption

A command result contains its outcome and both output streams. For example:

```json
{
  "result": {
    "outcome": {"completed": {"exited": 0}},
    "stdout": {
      "text": "hello\n",
      "truncated": false,
      "path": "/deployment/.ivenna/host/1/command.stdout.log"
    },
    "stderr": {
      "text": "",
      "truncated": false,
      "path": "/deployment/.ivenna/host/1/command.stderr.log"
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
| `text` | A preview of at most 16 KiB; longer output retains its beginning and end |
| `truncated` | Whether the preview omitted content |
| `path` | Absolute path to the complete output file |

The preview limit does not stop the command. Invalid UTF-8 bytes are replaced in previews; log files retain the original bytes. Logs remain under `.ivenna/host/<session_id>/` in the startup directory. Use subsequent shell calls to inspect them and remove unneeded files.

A timeout returns the output captured so far. Service cancellation also stops the process group. Neither action undoes completed changes. A restart may repeat a command whose result was not checkpointed; see [failure and recovery](architecture.md#failure-and-recovery).

Deployment maintainers can update the catalog and tool installations using the [development guide](development.md#managing-recommendations).
