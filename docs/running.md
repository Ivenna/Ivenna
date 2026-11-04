# Running Ivenna

These steps start the local HTTP service from the repository root. Ivenna stores application state in embedded SQLite. The default memory workspace runs in a container, while the service runs locally.

## Prerequisites and configuration

Install the Zig version specified in [`.zig-version`](../.zig-version) and an OpenSSH client. You also need a DeepSeek API key. The local memory workspace requires a container engine; [remote memory](#using-remote-memory) can be used instead. SQLite is compiled into the application, so it needs no separate service or command-line installation. Additional programs for the agent's [host shell](host.md) can be installed independently; see [optional host tools](#optional-host-tools).

Copy the configuration template from the repository root:

```sh
cp -n .env.example .env
```

Edit `.env` and set `LLM_API_KEY`. For the local memory workspace, also set `CONTAINER_ENGINE` to the container engine's command name or executable path. The memory startup script invokes it as a single executable. The template's `MEMORY_SSH_CONFIG` points to the SSH configuration file that the script will generate. Other settings are optional. Git ignores `.env` and the default `.ivenna/` data directory.

## Starting the service

In the same terminal, load the configuration, then start the memory container and the service:

```sh
set -a
. ./.env
set +a
dev/memory/start.sh up
zig build serve
```

On its first run, the [memory startup script](../dev/memory/start.sh) builds the image, creates a memory volume and SSH keys, writes the connection configuration to `.ivenna/dev-memory/`, and waits for the memory tools to become available. Later runs reuse the existing container, volume, and keys. The generated SSH configuration defines the target `ivenna-memory`, which connects to `127.0.0.1:2222` by default.

The service creates its local data directory and opens `state.sqlite` on startup. It listens on `http://127.0.0.1:5882` by default and calls `deepseek-flash` through the DeepSeek [Responses API](https://api-docs.deepseek.com/guides/responses_api/). Leave it running in this terminal and follow the [usage guide](usage.md) to submit input from another terminal. Run one service process per data directory: startup recovery assumes sole ownership of its sessions.

## Local data

`DATA_DIR` selects the service's local data directory. It defaults to `.ivenna`, relative to the startup directory; an absolute path can place data elsewhere. The service creates the directory with private permissions when it is missing. Use a location writable by the service account.

| Location | Contents |
| --- | --- |
| `<DATA_DIR>/state.sqlite` | Sessions, saved history, and pending inputs |
| `<DATA_DIR>/host/<session_id>/` | Full stdout and stderr files from host commands |
| Memory workspace selected by SSH configuration | Shared memory rooms and entries, stored as files |

The local memory setup keeps connection files and SSH keys in the repository's `.ivenna/dev-memory/` and memory content in its named container volume. Changing `DATA_DIR` moves neither of those locations. Keep the data directory and the selected memory workspace when continuing a deployment; [changing application data structures](development.md#changing-application-data-structures) explains how to reset development session data.

## Optional host tools

The [host shell](host.md) inherits the environment used to launch the service. Install additional programs on the host and make them executable by the service account. Include their locations in the service's `PATH` or invoke them by path. Restart the service to apply changes to its startup environment.

## Changing configuration

The startup commands export process variables from `.env`. The service reads its settings at startup. To change them, stop the service, edit `.env`, load the variables in a new terminal, and run `zig build serve` again. Memory backend settings follow the separate instructions below.

| Variable | Purpose | Default when unset |
| --- | --- | --- |
| `HOST` | HTTP listen address | `127.0.0.1` |
| `PORT` | HTTP listen port | `5882` |
| `LLM_API_KEY` | Model API key | Required |
| `LLM_BASE_URL` | Model API base URL | `https://api.deepseek.com` |
| `LLM_MODEL` | Model name | `deepseek-flash` |
| `DATA_DIR` | Local application data directory | `.ivenna`, relative to the startup directory |
| `MEMORY_SSH_TARGET` | Memory workspace SSH target | `ivenna-memory` |
| `MEMORY_SSH_CONFIG` | Dedicated SSH configuration file | Standard OpenSSH configuration; the local template sets `.ivenna/dev-memory/config` |
| `MEMORY_CAPACITY_BYTES` | Shared memory-room capacity in bytes; a positive integer set on the memory backend | `1073741824` (1 GiB) |

Relative paths such as `DATA_DIR` and the template's `MEMORY_SSH_CONFIG` resolve from the service's working directory. These instructions use the repository root. If you start the service elsewhere, adjust those paths or use absolute paths to continue using the same data and memory connection. Host commands also use the startup directory as their default working directory; their output files live under `DATA_DIR`.

`MEMORY_CAPACITY_BYTES` configures the capacity shared by all memory rooms. For a remote workspace, set it in the remote entry point's environment as described in [using remote memory](#using-remote-memory). The [memory guide](memory.md#memory-space) describes how Ivenna observes and enforces that capacity.

The local memory startup script passes `MEMORY_CAPACITY_BYTES` to the container when creating it. Use `MEMORY_SSH_PORT` to change the port, and `MEMORY_CONTAINER_NAME`, `MEMORY_VOLUME_NAME`, and `MEMORY_IMAGE` to choose the container, memory volume, and image names.

Changes to any of these local memory settings require recreating the container. Stop the service, run `dev/memory/start.sh down` with the original configuration, edit `.env`, load the variables in a new terminal, then run `dev/memory/start.sh up` and `zig build serve`. The memory volume and SSH keys are retained; choosing a different volume selects different memory content. To update the image contents after source changes, see [updating the service and memory container](development.md#updating-the-service-and-memory-container).

## Using remote memory

To connect to an existing remote workspace, configure SSH first, then follow the startup steps for the service, skipping the local memory container. This setup does not require a container engine.

The application uses the `ivenna-memory` SSH target by default. Set `MEMORY_SSH_TARGET` to use another target. To use your standard OpenSSH configuration, remove the template's `MEMORY_SSH_CONFIG` from `.env`; to use a dedicated configuration file, set it to that file's path. SSH configuration controls the user, hostname, keys, connection timeout, and host key verification.

The remote host needs Nushell, ripgrep, fd, `flock`, and GNU or BusyBox `stat` installed, along with two files at fixed locations:

- Install [memory.nu](../packages/agent/src/memory.nu) at `/usr/local/lib/ivenna/memory.nu`.
- Install `/usr/local/bin/memory-shell` using [memory-shell.sh](../dev/memory/memory-shell.sh) as a reference. This script changes to `/memory` and holds `/run/ivenna/memory.lock` while running the handler. Set `MEMORY_CAPACITY_BYTES` for these SSH sessions by exporting it in this script or configuring the SSH server's `SetEnv`.

The SSH account needs read and write access to the workspace and lock file. Create `/run/ivenna/` and its `memory.lock` file with access for that account when starting the memory service; the local container's [entry point](../dev/memory/entrypoint.sh) provides an example. All backend processes sharing a workspace must use the same lock file.

The application invokes this fixed entry point over SSH. Use the container's [Containerfile](../dev/memory/Containerfile) and [sshd_config](../dev/memory/sshd_config) as references for installation and SSH server configuration on a remote host.

## Stopping and restarting

Press `Ctrl+C` in the service terminal to stop Ivenna. If the memory workspace is still available, run `zig build serve` again with the same configuration to continue using saved sessions and memory.

To remove the local memory container as well, run:

```sh
dev/memory/start.sh down
```

This preserves the memory volume and SSH keys, and leaves the service's local data directory in place. Next time, repeat the steps for [starting the service](#starting-the-service). Run `dev/memory/start.sh status` to check the local memory container's status.
