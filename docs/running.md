# Running Ivenna

These steps start the local HTTP service from the repository root. In the default development environment, PostgreSQL and the memory workspace run in containers, while the Ivenna service runs locally.

## Prerequisites and configuration

Install the Zig version specified in [`.zig-version`](../.zig-version) and an OpenSSH client. You also need a DeepSeek API key and a container engine with Compose support.

Set `CONTAINER_ENGINE` to the local container engine's command name or executable path. It must be a single executable that supports container management commands and the `compose` subcommand. If your setup needs extra arguments or environment settings, put them in a wrapper script.

Copy the configuration template from the repository root:

```sh
cp -n .env.example .env
```

Edit `.env` and set `LLM_API_KEY` and `CONTAINER_ENGINE`. The template's `MEMORY_SSH_CONFIG` points to the SSH configuration file that the memory startup script will generate. Leave the remaining settings at their defaults. Git ignores `.env` and the local files generated during startup.

## Starting the service

In the same terminal, load the configuration, then start PostgreSQL, the memory container, and the service:

```sh
set -a
. ./.env
set +a
"$CONTAINER_ENGINE" compose up -d --wait db
dev/memory/start.sh up
zig build serve
```

On its first run, the [memory startup script](../dev/memory/start.sh) builds the image, creates a memory volume and SSH keys, writes the connection configuration to `.ivenna/dev-memory/`, and waits for the memory tools to become available. Later runs reuse the existing container, volume, and keys. The generated SSH configuration defines the target `ivenna-memory`, which connects to `127.0.0.1:2222` by default.

The service listens on `http://127.0.0.1:5882` by default and calls `deepseek-flash` through the DeepSeek [Responses API](https://api-docs.deepseek.com/guides/responses_api/). Leave it running in this terminal and follow the [usage guide](usage.md) to submit input from another terminal. Run only one service process against each application database.

## Changing configuration

The service reads configuration from its process environment. To change a setting, edit or add it in `.env`. Stop the service, then repeat the startup steps in a new terminal to load the updated configuration.

| Setting | Environment variables |
| --- | --- |
| HTTP listen address and port | `HOST`, `PORT` |
| Model API URL and model | `LLM_BASE_URL`, `LLM_MODEL` |
| Application session database connection | `DATABASE_URL` |
| Memory workspace SSH connection | `MEMORY_SSH_TARGET`, `MEMORY_SSH_CONFIG`; see [using remote memory](#using-remote-memory) |

The template sets `MEMORY_SSH_CONFIG` to a relative path, which the service resolves from its working directory. These instructions start the service from the repository root. If you start it elsewhere, set `MEMORY_SSH_CONFIG` to an absolute path.

Use `POSTGRES_PORT` and `POSTGRES_PASSWORD` to override the local PostgreSQL port and initial password. When changing the port, also update `DATABASE_URL`. When changing the password for an existing database, update both the database role and the connection URL. The password in the container environment is only used during initial setup; see the [PostgreSQL image documentation](https://github.com/docker-library/docs/tree/master/postgres#environment-variables).

For the local memory container, use `MEMORY_SSH_PORT` to change the port, and `MEMORY_CONTAINER_NAME`, `MEMORY_VOLUME_NAME`, and `MEMORY_IMAGE` to choose the container, memory volume, and image names.

These settings take effect when the container is created. Run `dev/memory/start.sh down` with the original configuration, update `.env`, load it in a new terminal, then run `dev/memory/start.sh up`. To update the image contents, see [updating the service and memory container](development.md#updating-the-service-and-memory-container).

## Using remote memory

To connect to an existing remote workspace, configure SSH first, then follow the startup steps for PostgreSQL and the service, skipping the local memory container.

The application uses the `ivenna-memory` SSH target by default. Set `MEMORY_SSH_TARGET` to use another target. To use your standard OpenSSH configuration, remove the template's `MEMORY_SSH_CONFIG` from `.env`; to use a dedicated configuration file, set it to that file's path. SSH configuration controls the user, hostname, keys, connection timeout, and host key verification.

The remote host needs Nushell, ripgrep, and fd installed, along with two files at fixed locations:

- Install [memory.nu](../packages/agent/src/memory.nu) at `/usr/local/lib/ivenna/memory.nu`.
- Install `/usr/local/bin/memory-shell` using [memory-shell.sh](../dev/memory/memory-shell.sh) as a reference. This script must change to `/memory` before running the handler. The SSH account needs read and write access to this workspace.

The application invokes this fixed entry point over SSH. Use the container's [Containerfile](../dev/memory/Containerfile) and [sshd_config](../dev/memory/sshd_config) as references for installation and SSH server configuration on a remote host.

## Stopping and restarting

Press `Ctrl+C` in the service terminal to stop Ivenna. If PostgreSQL and the memory container are still running, run `zig build serve` again to continue using saved sessions and memory.

To stop the local containers as well, run:

```sh
dev/memory/start.sh down
"$CONTAINER_ENGINE" compose down
```

These commands preserve data volumes and SSH keys. Next time, repeat the steps for [starting the service](#starting-the-service). Run `dev/memory/start.sh status` to check the local memory container's status.
