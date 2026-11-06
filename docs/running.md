# Running Ivenna

Run the Ivenna kernel locally, with a mail account and an SSH workspace for autonomous memory. This guide covers configuration, service preparation, startup, and reception checks. Run commands from the repository root.

## Prerequisites and configuration

Install the Zig version in [`.zig-version`](../.zig-version) and an OpenSSH client. The supplied local middleware uses [dev/compose.yaml](../dev/compose.yaml) with [Docker Compose](https://docs.docker.com/compose/) or [Podman Compose](https://docs.podman.io/en/latest/markdown/podman-compose.1.html); the examples below use Podman.

The application uses the Responses adapter with DeepSeek as the default model service. Supply its API key, or configure a Responses-compatible endpoint and model through `LLM_BASE_URL` and `LLM_MODEL`.

Create the configuration file:

```sh
cp -n .env.example .env
```

Set `LLM_API_KEY` and configure the mail and memory connections. The sample settings match the supplied local services. For [existing mail](#using-an-existing-mail-service) or [remote memory](#using-remote-memory), configure those connections and prepare only the services you run locally.

The kernel authenticates with `MAIL_*`; the [correspondence example](usage.md#sending-a-request) uses `OPERATOR_MAIL_ADDRESS` and `OPERATOR_MAIL_PASSWORD` for a separate account. Keep local account credentials aligned with the private [mail provisioning plan](#configuring-local-mail).

The kernel, Compose, and memory preparation script use the exported configuration. Load `.env` in each terminal used for these commands, and reload it after editing its values:

```sh
set -a
. ./.env
set +a
```

Git ignores the credential files `.env` and `dev/mail/provision.ndjson`, as well as the default `.ivenna/` data directory. The [kernel settings](#changing-configuration) and [local middleware settings](#local-middleware-settings) record their defaults and how to apply changes.

## Preparing local services

Before provisioning or starting local services for the first time, create their external data volumes:

```sh
podman volume create "${MAIL_VOLUME_NAME:-ivenna-mail}"
podman volume create "${MEMORY_VOLUME_NAME:-ivenna-memory}"
```

Create only the corresponding volume when using one local service. Existing setups reuse their volumes. The [data reference](#local-data) lists their contents and the SSH files retained outside them.

When replacing independently managed local middleware with this Compose project, stop the kernel and remove the old containers before the preparation below. Retain the named volumes and `.ivenna/dev-memory/` to reuse their data and SSH keys.

### Configuring local mail

Stalwart stores accounts and receiving policy in its data volume. Prepare a private provisioning plan before first use:

```sh
cp -n dev/mail/provision.example.ndjson dev/mail/provision.ndjson
chmod 600 dev/mail/provision.ndjson
```

Set the account credentials in the plan and put the matching kernel and operator credentials in `.env`. The example defines three accounts:

| Address | Role | Example password |
| --- | --- | --- |
| `ivenna@ivenna.test` | Dedicated kernel mailbox | `ivenna-local-password` |
| `operator@ivenna.test` | Send messages and read Ivenna's mail | `operator-local-password` |
| `admin@ivenna.test` | Stalwart administration | `admin-local-password` |

The plan also defines the `ivenna-ready` script and its `MtaStageRcpt` rule. Set the script's recipient to Ivenna's address and its readiness URL to an endpoint reachable from the mail container. The example uses `ivenna@ivenna.test` and `http://host.containers.internal:8090/readyz`; Compose maps that host name to the host. Keep the address and URL aligned with `MAIL_ADDRESS` and `SERVICE_ADDRESS`. See [reception readiness](#service-status-and-reception) for the policy's scope.

When updating a private plan, preserve the deployment's accounts, credentials, and domains. Keep the readiness gate for Ivenna's address and the domain's disabled `subAddressing` setting. Restarting a container does not update this stored policy.

To apply the initial plan or later edits, stop the kernel, load the updated `.env`, and run:

```sh
podman compose -f dev/compose.yaml -f dev/mail/setup.yaml up -d --wait mail
podman compose -f dev/compose.yaml -f dev/mail/setup.yaml run --rm --no-deps provision
```

The [setup override](../dev/mail/setup.yaml) starts Stalwart in recovery mode for the official CLI to apply the plan. `MAIL_SETUP_PASSWORD` controls the temporary setup credential; the administrator account in the plan supplies normal administration credentials. Applying the plan can replace account passwords.

The mail service remains in recovery mode until [normal startup](#starting-the-kernel) recreates it without the setup override. Later starts reuse its stored configuration; apply the plan again when that configuration changes.

The default local endpoints are:

| Interface | Address |
| --- | --- |
| JMAP session | `http://127.0.0.1:8088/jmap/session` |
| Authenticated SMTP submission | `127.0.0.1:2525` |
| Stalwart administration | `http://127.0.0.1:8088/admin` |

Published ports bind to loopback. The plan requires authenticated submission with a matching sender; its listener, spam, and rate policies are defined in the plan. Stalwart stores mail, accounts, and configuration in the external volume, which remains after the Compose containers are removed.

### Configuring local memory

Prepare the SSH connection and build the memory image from the current source:

```sh
dev/memory/prepare.sh
podman compose -f dev/compose.yaml build memory
```

The preparation script creates or reuses the client and host keys under `.ivenna/dev-memory/` and writes the `ivenna-memory` SSH target to its `config` file, matching the sample `MEMORY_SSH_CONFIG`. It pins the generated host key for verification. The default endpoint is `127.0.0.1:2222`.

Later starts reuse this image and connection. After changing the handler or container sources, follow the [memory rebuild steps](development.md#updating-the-kernel-and-middleware). Changes to the local port or capacity follow the [middleware settings](#local-middleware-settings).

## Mail intake

Reserve the kernel account and its sending identity for Ivenna. Use the operator account, or another correspondent account, to send messages and receive Ivenna's outgoing mail. The kernel reads ordinary unprocessed correspondence across mail folders, including Archive. Drafts and messages in Junk or Trash are excluded, along with the runtime's own outgoing and internal state records.

Ivenna tracks processing with a private completion marker. Eligible mail without that marker is pending, including existing mail that has been read or archived. Review the mailbox before connecting it; reading, starring, or moving ordinary correspondence does not mark it as processed.

## Starting the kernel

After preparing the services, load the configuration and start them with the kernel. The commands below start both local services. If only one is local, name it (`mail` or `memory`) in the Compose command; if both are external, skip that command.

```sh
set -a
. ./.env
set +a
podman compose -f dev/compose.yaml up -d --wait
zig build run
```

Compose waits for the mail health endpoint and memory SSH listener. It reuses the volumes and applies changed service settings when recreating containers.

`zig build run` builds and runs the kernel. Startup discovers the mail account and checks memory with a read-only space inspection. Both must succeed before Ivenna can run. Keep the kernel running in this terminal and use one kernel per mailbox. From a second terminal, check [reception readiness](#service-status-and-reception) before following the [usage guide](usage.md) to send a message.

Startup diagnostics appear in the kernel's terminal and the `mail` and `memory` service logs.

## Service status and reception

`SERVICE_ADDRESS` selects the kernel's HTTP listener and defaults to `0.0.0.0:8090`. While the listener is running, it exposes:

| Endpoint | Response |
| --- | --- |
| `GET /healthz` | `200 OK` for listener health |
| `GET /readyz` | `200 OK` with `X-Ivenna-Ready: true` when reception is open; otherwise `503 Service Unavailable` |

Reception opens after startup checks and core context preparation. It closes when the runtime stops or fails. These endpoints report lifecycle state; they do not probe mail or memory on each request. Once the process has exited, its listener is also gone. Check the current state from another terminal:

```sh
curl --include http://127.0.0.1:8090/readyz
```

The supplied Stalwart plan checks `http://host.containers.internal:8090/readyz` during SMTP `RCPT` handling for `ivenna@ivenna.test`. If the readiness header is absent, including when the endpoint cannot be reached, it rejects the recipient with `550`.

The example defines one receiving address for Ivenna and disables subaddressing. Adding aliases or another path to the account requires a policy that gates those addresses too.

Readiness describes the kernel's reception state when queried. It reserves no processing capacity, and the runtime can stop after a successful check or accepted delivery. The SMTP gate does not cover JMAP imports or delivery between accounts through the same server's JMAP interface. The kernel continues to read [ordinary unprocessed mail](#mail-intake) already present in its mailbox.

The rejection reaches the sending SMTP server during that delivery attempt. A normal mail client may already have submitted to its own server, which handles the delivery result. Connection failures can also lead that server to queue and retry mail. See SMTP's [delivery responsibilities](https://www.rfc-editor.org/rfc/rfc5321.html#section-4.2.5) and [retry behavior](https://www.rfc-editor.org/rfc/rfc5321.html#section-4.5.4.1).

## Stopping and restarting

Press `Ctrl+C` in the kernel terminal to close reception and wait for its workers to end. Communication or memory infrastructure failures and errors propagated by execution also stop the whole kernel. Diagnose the failure from the terminal output and restore any unavailable services before restarting.

An interrupted operation may already have changed files, memory, or mail. Inspect uncertain effects before restarting. With the same environment and services running, use `zig build run` again. Ivenna reconstructs its understanding from retained material; see [after interruption](usage.md#after-interruption) for what continuation means.

To remove the local middleware containers while retaining mail, memory, and SSH keys:

```sh
podman compose -f dev/compose.yaml down
```

Use [normal startup](#starting-the-kernel) to start the services and kernel again.

## Changing configuration

The settings below configure the kernel. Stop it, edit `.env`, reload the variables, and run `zig build run`. When removing a variable from `.env`, also unset its previously exported value or start a new terminal.

| Variable | Purpose | Default when unset |
| --- | --- | --- |
| `LLM_API_KEY` | Model API key | Required |
| `LLM_BASE_URL` | Model API base URL | `https://api.deepseek.com` |
| `LLM_MODEL` | Model name | `deepseek-flash` |
| `LLM_MAX_OUTPUT_TOKENS` | Maximum generated tokens per response | `8192` |
| `SERVICE_ADDRESS` | HTTP health and reception-readiness listener | `0.0.0.0:8090` |
| `MAIL_SESSION_URL` | JMAP session URL | `http://127.0.0.1:8088/jmap/session` |
| `MAIL_ADDRESS` | Kernel address and sending identity | `ivenna@ivenna.test` |
| `MAIL_USERNAME` | Mail login | Required for username/password authentication |
| `MAIL_PASSWORD` | Mail password | Required for username/password authentication |
| `MAIL_AUTHORIZATION` | Complete HTTP Authorization header | Unset; use username/password |
| `MAIL_POLL_INTERVAL_MS` | Delay between mail polls | `2000` |
| `MAX_PARALLEL_ATTENTION` | Maximum concurrently executing work sessions; core has a separate lane | `4` |
| `MAX_ATTENTION_CONTEXTS` | Maximum retained contexts, including the core; also sets each session's capacity | `32` |
| `CONTEXT_REQUEST_BYTES` | Maximum complete serialized ordinary model request | `65536` |
| `CONTEXT_COMPACTION_BYTES` | Maximum complete serialized summary request | `131072` |
| `HANDOVER_MAX_BYTES` | Maximum retained handover text | `8192` |
| `DATA_DIR` | Local artifact directory | `.ivenna` |
| `MEMORY_SSH_TARGET` | Memory SSH target | `ivenna-memory` |
| `MEMORY_SSH_CONFIG` | Dedicated SSH configuration file | Standard OpenSSH configuration |

`MAIL_AUTHORIZATION` takes precedence over username/password authentication. `SERVICE_ADDRESS` must contain a literal IP address and a nonzero port; keep the [mail readiness policy](#service-status-and-reception) aligned when changing it. Numeric kernel settings must be positive. `CONTEXT_COMPACTION_BYTES` must be at least `CONTEXT_REQUEST_BYTES`. The work execution limit and retained-context limit are independent.

Parents waiting for descendants count toward the context limit without occupying execution slots. The same limit bounds each session's active and queued events plus reserved child reports; batching events does not reduce that count. With `MAX_ATTENTION_CONTEXTS=1`, only the core fits and forking is unavailable. At capacity, pending mail remains available for later polling. See [session capacity](architecture.md#sessions-work-and-communication) for scheduling behavior.

Request byte limits cover the whole serialized body, including instructions, tool definitions, history, and encoded images. They do not estimate model tokens. See [bounded model context](architecture.md#bounded-model-context) for compaction and budget failures.

Relative `DATA_DIR` and `MEMORY_SSH_CONFIG` paths resolve from the kernel's startup directory.

## Local middleware settings

These settings configure the supplied local services in [dev/compose.yaml](../dev/compose.yaml). Stop the kernel before recreating a service.

| Variable | Purpose | Default when unset |
| --- | --- | --- |
| `MAIL_CONTAINER_NAME` | Stalwart container name | `ivenna-mail` |
| `MAIL_VOLUME_NAME` | Existing external Stalwart volume | `ivenna-mail` |
| `MAIL_HTTP_PORT` | Loopback HTTP/JMAP port | `8088` |
| `MAIL_SMTP_PORT` | Loopback SMTP submission port | `2525` |
| `MAIL_SETUP_PASSWORD` | Temporary recovery-mode credential | `local-setup-password` |
| `MEMORY_SSH_PORT` | Loopback memory SSH port | `2222` |
| `MEMORY_CONTAINER_NAME` | Memory container name | `ivenna-memory` |
| `MEMORY_VOLUME_NAME` | Existing external memory data volume | `ivenna-memory` |
| `MEMORY_IMAGE` | Memory image | `localhost/ivenna-memory:dev` |
| `MEMORY_CAPACITY_BYTES` | Shared memory-room capacity | `1073741824` (1 GiB) |

If changing the mail HTTP port, update `MAIL_SESSION_URL` too. Account and server policy changes belong in the private provisioning plan; apply them through [local mail setup](#configuring-local-mail).

After changing service settings, reload `.env` and use [normal startup](#starting-the-kernel) to recreate affected containers. If changing `MEMORY_SSH_PORT`, first run `dev/memory/prepare.sh` again to update the SSH connection. Existing volumes and SSH keys remain in place. Changing `MAIL_VOLUME_NAME` or `MEMORY_VOLUME_NAME` selects different storage; create that volume before startup, and transfer existing data separately if needed.

Source changes inside the memory image require a [rebuild](development.md#updating-the-kernel-and-middleware). For a remote memory workspace, configure capacity at its entry point; see [memory space](memory.md#memory-space).

## Local data

`DATA_DIR` selects the kernel's artifact and contact directory. The kernel creates it with private permissions when missing. Mail storage, the memory workspace, and local SSH connection files have separate locations:

| Location | Contents |
| --- | --- |
| Stalwart volume, `ivenna-mail` by default | Mail, handovers, accounts, and Stalwart configuration |
| Memory volume, `ivenna-memory` by default | Shared memory rooms and entries for the local service |
| `dev/mail/provision.ndjson` | Private mail configuration plan |
| `<DATA_DIR>/host/<session_id>/` | Full stdout and stderr from host commands |
| `<DATA_DIR>/sources/` | Captured input text and decoded mail snapshots |
| `<DATA_DIR>/contacts/` | Persistent mappings from contact references to delivery addresses |
| `.ivenna/dev-memory/` | Local memory SSH configuration and keys |
| Remote memory workspace, when configured | Shared memory rooms and entries |

Changing `DATA_DIR` changes where the kernel writes artifacts; it does not move existing files, middleware volumes, or the SSH connection files under the repository's `.ivenna/dev-memory/` directory.

Contact mappings let retained recipient references remain usable after a working context ends or the source cache is cleared. Preserve these files when moving deployment data; removing a mapping can make a retained reference unavailable for sending.

Source files let a work session retrieve the complete material behind an excerpt and inspect mail details when needed. Correspondence text includes the subject and body supplied as input; JSON snapshots contain decoded fields rather than original MIME or live mailbox state. These files remain after the work finishes. See [source materials](architecture.md#email-boundary-and-source-materials) for their naming and publication contract.

Core handovers are self-addressed state records stored in the mailbox's Archive folder when the core context is compacted. Work sessions compact in memory. Saving a handover or releasing working context leaves source letters in their existing folders. Manage mailbox capacity through retention and deletion. Automatic mail retention and coordinated artifact cleanup are not implemented; see [mail retention](architecture.md#mail-retention).

## Using an existing mail service

Use a dedicated account with JMAP Mail and Submission capabilities and a sending identity matching `MAIL_ADDRESS`. The account needs Sent and Drafts folders and permission to create messages and update private keywords. Ivenna uses the Archive folder when present and creates it when missing, so that operation also needs permission.

Set the account's `MAIL_SESSION_URL`, `MAIL_ADDRESS`, and authentication settings in `.env`, then skip local mail provisioning and startup. Use another account to send messages and read Ivenna's mail; reserve the Ivenna identity for the runtime's submissions.

Configure the mail service's receiving policy to consult Ivenna's [reception readiness](#service-status-and-reception) and reject incoming traffic while reception is closed. Use that gated path for external messages. JMAP access alone does not enforce the reception contract.

Correspondence and core state records share the mailbox. The [intake rules](#mail-intake) also apply to its existing mail. Configure service retention to preserve correspondence and core handovers needed for later continuation.

## Using remote memory

Configure SSH to an existing workspace and skip local memory preparation and startup. Set `MEMORY_SSH_TARGET` to its SSH target. Set `MEMORY_SSH_CONFIG` to a dedicated file, or remove it from `.env` and unset its exported value to use normal OpenSSH configuration:

```sh
unset MEMORY_SSH_CONFIG
```

SSH configuration controls the host, user, keys, timeout, and host key verification. The remote host needs Nushell, ripgrep, fd, `flock`, and GNU or BusyBox `stat`. Use the Nushell version selected by the [Containerfile](../apps/memory/Containerfile), and install the programs on the `PATH` used by the memory shell. Prepare two fixed entry points:

- Install [memory.nu](../apps/memory/src/memory.nu) at `/usr/local/lib/ivenna/memory.nu`.
- Install `/usr/local/bin/memory-shell` using [memory-shell.sh](../apps/memory/memory-shell.sh) as a reference. Set its working directory to your memory workspace; the supplied script uses `/memory`. It holds `/run/ivenna/memory.lock` while running the handler. Export `MEMORY_CAPACITY_BYTES` there or use the SSH server's `SetEnv`.

The SSH account needs read and write access to the workspace and lock. Create `/run/ivenna/` and `memory.lock` for that account at startup; [entrypoint.sh](../apps/memory/entrypoint.sh) provides an example. All handler processes sharing the workspace must use the same lock.

Use [sshd_config](../apps/memory/sshd_config) as a reference for the SSH entry point.

## Optional host tools

Host commands use the kernel's startup directory by default and inherit its environment. Install additional programs on the host and make them executable by the kernel's OS account. Include their locations in `PATH` or invoke them by path. Restart the kernel to apply startup environment changes.
