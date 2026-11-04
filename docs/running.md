# Running Ivenna

Run the kernel locally, with Stalwart for mail and an SSH workspace for autonomous memory. The steps below set up the supplied local middleware; [existing mail](#using-an-existing-mail-service) and [remote memory](#using-remote-memory) can replace either service. Run commands from the repository root.

## Prerequisites and configuration

Install the Zig version in [`.zig-version`](../.zig-version), an OpenSSH client, and Podman with a Compose provider. The first build and middleware startup need network access to download dependencies and images. The default model provider is DeepSeek; supply its API key, or configure a Responses-compatible endpoint and model through `LLM_BASE_URL` and `LLM_MODEL`.

Create the configuration file:

```sh
cp -n .env.example .env
```

Set `LLM_API_KEY`. The example mailbox and operator credentials match the [mail provisioning example](../dev/mail/provision.example.ndjson); keep them aligned with the private plan prepared in the next section. `OPERATOR_MAIL_ADDRESS` and `OPERATOR_MAIL_PASSWORD` are used by the mail submission examples. The kernel uses the separate `MAIL_*` account.

The application reads its process environment. Load `.env` in each terminal that starts Ivenna, its middleware, or the submission example:

```sh
set -a
. ./.env
set +a
```

Git ignores `.env`, the default `.ivenna/` directory, and `dev/mail/provision.ndjson`. [Configuration references](#changing-configuration) below distinguish kernel settings from middleware settings.

## Configuring local mail

For a new mail volume, copy the native Stalwart plan:

```sh
cp -n dev/mail/provision.example.ndjson dev/mail/provision.ndjson
chmod 600 dev/mail/provision.ndjson
```

Edit its account credentials and put the matching kernel and operator credentials in `.env`. The example defines three accounts:

| Address | Role | Example password |
| --- | --- | --- |
| `ivenna@ivenna.test` | Kernel mailbox | `ivenna-local-password` |
| `operator@ivenna.test` | Send requests and read replies | `operator-local-password` |
| `admin@ivenna.test` | Stalwart administration | `admin-local-password` |

With `.env` loaded, create the external data volume, apply the plan, and start the normal service:

```sh
podman volume create "${MAIL_VOLUME_NAME:-ivenna-mail}"
podman compose -f dev/mail/compose.yaml -f dev/mail/setup.yaml run --rm provision
podman compose -f dev/mail/compose.yaml up -d --wait mail
```

The [setup override](../dev/mail/setup.yaml) starts Stalwart in recovery mode for the official CLI to apply the plan. The final command recreates the service with [normal configuration](../dev/mail/compose.yaml). `MAIL_SETUP_PASSWORD` controls the temporary setup credential; the administrator account in the plan supplies normal administration credentials.

For an initialized volume, use normal startup with its existing credentials. Apply the plan again when deliberately changing account or server configuration; it can replace passwords.

The default local endpoints are:

| Interface | Address |
| --- | --- |
| JMAP session | `http://127.0.0.1:8088/jmap/session` |
| Authenticated SMTP submission | `127.0.0.1:2525` |
| Stalwart administration | `http://127.0.0.1:8088/admin` |

Published ports bind to loopback. The plan requires authenticated submission with a matching sender; its listener, spam, and rate policies are defined in the plan. Stalwart stores mail, accounts, and configuration in the external volume, which remains after the Compose containers are removed.

## Starting the kernel

For both the first run and later starts:

```sh
set -a
. ./.env
set +a
podman compose -f dev/mail/compose.yaml up -d --wait mail
dev/memory/start.sh up
zig build run
```

The memory script uses `CONTAINER_ENGINE` from the environment; `.env.example` selects `podman`. When creating a container, it builds the image and prepares a volume and SSH keys. It writes connection configuration to `.ivenna/dev-memory/` and waits for the memory tools to respond. The default target is `ivenna-memory` at `127.0.0.1:2222`. Subsequent starts reuse the container, volume, and keys.

`zig build run` builds and runs the local kernel. Keep it running in this terminal, using one kernel per Ivenna mailbox. When it reports that it is receiving mail, follow the [usage guide](usage.md) to send a request from a second terminal or mail client.

For startup diagnostics, inspect the kernel's terminal output and the middleware state:

```sh
podman compose -f dev/mail/compose.yaml ps
dev/memory/start.sh status
```

## Stopping and restarting

Press `Ctrl+C` in the kernel terminal. With the same environment and middleware still running, use `zig build run` again to continue corresponding. The kernel reconstructs its understanding from mail and handovers; suspended model requests and individual tool results remain part of the previous process's runtime history.

To remove the local middleware containers while retaining mail, memory, and SSH keys:

```sh
podman compose -f dev/mail/compose.yaml down
dev/memory/start.sh down
```

Repeat [normal startup](#starting-the-kernel) when needed. Source, prompt, and container changes have their own rebuild steps in the [development guide](development.md#updating-the-kernel-and-middleware).

## Changing configuration

The kernel reads the settings below at startup. Stop it, edit `.env`, load the variables again, and run `zig build run`. When removing a variable from `.env`, also unset its previously exported value or start a new terminal.

| Variable | Purpose | Default when unset |
| --- | --- | --- |
| `LLM_API_KEY` | Model API key | Required |
| `LLM_BASE_URL` | Model API base URL | `https://api.deepseek.com` |
| `LLM_MODEL` | Model name | `deepseek-flash` |
| `LLM_MAX_OUTPUT_TOKENS` | Maximum generated tokens per response | `8192` |
| `MAIL_SESSION_URL` | JMAP session URL | `http://127.0.0.1:8088/jmap/session` |
| `MAIL_ADDRESS` | Kernel address and sending identity | `ivenna@ivenna.test` |
| `MAIL_USERNAME` | Mail login | Required for username/password authentication |
| `MAIL_PASSWORD` | Mail password | Required for username/password authentication |
| `MAIL_AUTHORIZATION` | Complete HTTP Authorization header | Unset; use username/password |
| `MAIL_POLL_INTERVAL_MS` | Delay between mail polls | `2000` |
| `MAX_PARALLEL_ATTENTION` | Maximum concurrently executing sessions | `4` |
| `MAX_ATTENTION_CONTEXTS` | Maximum retained contexts, including the permanent core | `32` |
| `CONTEXT_REQUEST_BYTES` | Maximum complete serialized ordinary model request | `65536` |
| `CONTEXT_COMPACTION_BYTES` | Maximum complete serialized summary request | `131072` |
| `HANDOVER_MAX_BYTES` | Maximum retained handover text | `8192` |
| `DATA_DIR` | Local artifact directory | `.ivenna` |
| `MEMORY_SSH_TARGET` | Memory SSH target | `ivenna-memory` |
| `MEMORY_SSH_CONFIG` | Dedicated SSH configuration file | Standard OpenSSH configuration |

`MAIL_AUTHORIZATION` takes precedence over username/password authentication. Numeric kernel settings must be positive. `CONTEXT_COMPACTION_BYTES` must be at least `CONTEXT_REQUEST_BYTES`, and `MAX_ATTENTION_CONTEXTS` must be at least `MAX_PARALLEL_ATTENTION`.

The context limit counts the core and active branches. Archiving releases branch contexts, and additional input waits in Inbox when capacity is occupied. Request limits measure the whole serialized body, including instructions, tool definitions, observations, history, and encoded images. A model-specific token and image estimator remains planned; see [bounded model context](architecture.md#bounded-model-context).

Relative `DATA_DIR` and `MEMORY_SSH_CONFIG` paths resolve from the kernel's startup directory.

## Local middleware settings

Compose reads the mail settings when creating the service. The memory script reads its settings when starting or creating the memory container. Stop the kernel before recreating middleware and retain its storage.

| Variable | Purpose | Default when unset |
| --- | --- | --- |
| `MAIL_CONTAINER_NAME` | Stalwart container name | `ivenna-mail` |
| `MAIL_VOLUME_NAME` | Existing external Stalwart volume | `ivenna-mail` |
| `MAIL_HTTP_PORT` | Loopback HTTP/JMAP port | `8088` |
| `MAIL_SMTP_PORT` | Loopback SMTP submission port | `2525` |
| `MAIL_SETUP_PASSWORD` | Temporary recovery-mode credential | `local-setup-password` |
| `CONTAINER_ENGINE` | Container CLI used by the memory script | Required; `.env.example` uses `podman` |
| `MEMORY_SSH_PORT` | Loopback memory SSH port | `2222` |
| `MEMORY_CONTAINER_NAME` | Memory container name | `ivenna-memory` |
| `MEMORY_VOLUME_NAME` | Memory data volume | `ivenna-memory` |
| `MEMORY_IMAGE` | Memory image | `localhost/ivenna-memory:dev` |
| `MEMORY_CAPACITY_BYTES` | Shared memory-room capacity | `1073741824` (1 GiB) |

If changing the mail HTTP port, update `MAIL_SESSION_URL` too. Create a selected external mail volume before first use. Account and mail policy changes belong in the private provisioning plan. Mail images are pinned in the Compose files.

Memory port, image, and capacity changes take effect when the memory container is created. Remove the existing container with its current settings using `dev/memory/start.sh down`, then load the changed settings and run `up`. The volume and SSH keys are retained. For a remote memory workspace, configure capacity at its entry point; see [memory space](memory.md#memory-space).

## Local data

`DATA_DIR` selects the artifact directory, relative to the startup directory or as an absolute path. The kernel creates it with private permissions when missing. Mail storage, the memory workspace, and the local memory startup script's state have separate locations:

| Location | Contents |
| --- | --- |
| Stalwart volume, `ivenna-mail` by default | Mail, handovers, accounts, and Stalwart configuration |
| `dev/mail/provision.ndjson` | Private mail configuration plan |
| `<DATA_DIR>/host/<session_id>/` | Full stdout and stderr from host commands |
| `<DATA_DIR>/mail/<sha256-of-mail-id>.txt` | Full input bodies for model context and host inspection |
| `.ivenna/dev-memory/` | Local memory SSH configuration and keys |
| Memory workspace selected by SSH configuration | Shared memory rooms and entries |

Changing `DATA_DIR` changes the kernel's artifact location; existing files and middleware volumes stay where they are. Archiving keeps source letters, handovers, and artifacts while releasing working contexts. Coordinated deletion of archived correspondence and its local artifacts is not implemented; mail retention and artifact cleanup are managed separately.

## Using an existing mail service

Use a dedicated account with JMAP Mail and Submission capabilities and a sending identity matching `MAIL_ADDRESS`. The account needs Inbox, Sent, and Drafts folders and permission to create and update mail. Ivenna uses the Archive folder when present and creates it when missing, so that operation also needs permission.

Set the account's `MAIL_SESSION_URL`, `MAIL_ADDRESS`, and authentication settings in `.env`, then skip local mail provisioning and startup. Use another account to send requests and read replies. Marking letters read in Ivenna's account affects intake.

The service owns delivery and retention policy. Retain source correspondence and handovers when preserving continuity. Reception currently uses polling; notification streaming and mail attachment intake remain placeholders.

## Using remote memory

Configure SSH to an existing workspace and skip `dev/memory/start.sh up`. Set `MEMORY_SSH_TARGET` to its SSH target. Set `MEMORY_SSH_CONFIG` to a dedicated file, or remove it from `.env` and unset its exported value to use normal OpenSSH configuration:

```sh
unset MEMORY_SSH_CONFIG
```

SSH configuration controls the host, user, keys, timeout, and host key verification. The remote host needs Nushell, ripgrep, fd, `flock`, and GNU or BusyBox `stat`, together with two fixed entry points:

- Install [memory.nu](../packages/agent/src/memory.nu) at `/usr/local/lib/ivenna/memory.nu`.
- Install `/usr/local/bin/memory-shell` using [memory-shell.sh](../dev/memory/memory-shell.sh) as a reference. It changes to `/memory` and holds `/run/ivenna/memory.lock` while running the handler. Export `MEMORY_CAPACITY_BYTES` there or use the SSH server's `SetEnv`.

The SSH account needs read and write access to the workspace and lock. Create `/run/ivenna/` and `memory.lock` with access for that account at startup; [entrypoint.sh](../dev/memory/entrypoint.sh) provides an example. All backend processes sharing the workspace must use the same lock.

Use the [Containerfile](../dev/memory/Containerfile) and [sshd_config](../dev/memory/sshd_config) as references for remote installation.

## Optional host tools

Host commands use the kernel's startup directory by default and inherit its environment. Install additional programs on the host and make them executable by the kernel's OS account. Include their locations in `PATH` or invoke them by path. Restart the kernel to apply startup environment changes.
