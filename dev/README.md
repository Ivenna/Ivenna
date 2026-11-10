# Local development

This setup runs the kernel from the source checkout, with mail and memory services managed by [compose.yaml](compose.yaml). A private instance directory holds configuration and SSH keys; external service volumes hold mail and memory. Run the commands from the repository root. For runtime requirements and other service arrangements, see the [running guide](../docs/running.md).

## Prerequisites

Install the Zig version in [`.zig-version`](../.zig-version), an OpenSSH client, and `curl`.

Use [Docker Compose](https://docs.docker.com/compose/) or [Podman Compose](https://docs.podman.io/en/latest/markdown/podman-compose.1.html) for the middleware. The commands below use Podman. The [development guide](../docs/development.md) covers build conventions and validation.

## Configuration

Choose an absolute path for the private instance directory and prepare it. This example keeps it outside the source checkout:

```sh
export DEV_INSTANCE_DIR="$HOME/ivenna-dev"
dev/prepare.sh
```

The preparation script copies [.env.example](../.env.example) to `$DEV_INSTANCE_DIR/.env` and the [mail plan example](mail/provision.example.ndjson) to `$DEV_INSTANCE_DIR/mail/provision.ndjson`. Running it again preserves existing private files.

Edit the instance's `.env` to set `LLM_API_KEY` and configure the mail and memory connections. Set matching account credentials in `.env` and the private mail plan as described in [mail setup](#configuring-mail). The kernel authenticates with `MAIL_*`; the [message example](#sending-a-message) uses `OPERATOR_MAIL_ADDRESS` and `OPERATOR_MAIL_PASSWORD` for a separate account in the same domain as `MAIL_ADDRESS`.

The kernel requires `DATA_DIR`; the example sets it to `$DEV_INSTANCE_DIR/data` and uses `$DEV_INSTANCE_DIR/memory/config` for `MEMORY_SSH_CONFIG`. The sample connections match the local services below. To use another [mail service](../docs/running.md#mail-service) or [memory workspace](../docs/running.md#memory-service), configure those connections and prepare only the services you run locally.

In each terminal used for development commands, export your chosen `DEV_INSTANCE_DIR` and load its `.env` file. Reload it after editing its values:

```sh
export DEV_INSTANCE_DIR="$HOME/ivenna-dev"
set -a
. "$DEV_INSTANCE_DIR/.env"
set +a
```

The kernel and memory preparation script use the exported environment. The Compose commands also select the instance configuration explicitly with `--env-file`. See [kernel settings](../docs/running.md#configuration) and [local service settings](#service-settings) for defaults and how to apply changes.

## Preparing service storage

Before provisioning or starting local services for the first time, create their external data volumes:

```sh
podman volume create "${MAIL_VOLUME_NAME:-ivenna-mail}"
podman volume create "${MEMORY_VOLUME_NAME:-ivenna-memory}"
```

Create only the corresponding volume when using one local service. Existing setups reuse their volumes. The [local data reference](#development-data) lists their contents and the SSH files retained outside them.

## Configuring mail

Stalwart stores accounts, receiving rules, and retention settings in its data volume. The private plan at `$DEV_INSTANCE_DIR/mail/provision.ndjson` defines them. Keep its kernel and operator credentials aligned with the instance's `.env`. The example defines three accounts:

| Address | Role | Example password |
| --- | --- | --- |
| `ivenna@ivenna.test` | Dedicated kernel mailbox | `ivenna-local-password` |
| `operator@ivenna.test` | Send requests and receive Ivenna's messages | `operator-local-password` |
| `admin@ivenna.test` | Stalwart administration | `admin-local-password` |

The plan requires authenticated SMTP submission. `MtaStageAuth.mustMatchSender` checks that the account may use the SMTP envelope sender. At `DATA`, the `ivenna-sender` script selected by `MtaStageData` requires exactly one From address matching that sender, ignoring case. See Stalwart's [sender verification](https://stalw.art/docs/mta/inbound/auth/#sender-verification) and [From-header example](https://stalw.art/docs/sieve/examples/#require-the-from-header-to-match-the-sender-of-authenticated-mail).

The plan's `ivenna-ready` script runs during SMTP `RCPT` handling through its `MtaStageRcpt` rule. Set the script's recipient to Ivenna's address and its readiness URL to an endpoint reachable from the mail container. The example uses `ivenna@ivenna.test` and `http://host.containers.internal:8090/readyz`; Compose maps that host name to the host. Keep the address and URL aligned with `MAIL_ADDRESS` and `SERVICE_ADDRESS`.

The script rejects that recipient with `550` when the readiness header is absent or the endpoint cannot be reached. The example defines one receiving address and disables subaddressing. Adding aliases or another path to the account requires a policy that gates those addresses too. See [reception readiness](../docs/running.md#service-status-and-reception) for the status contract.

Use the SMTP submission path for correspondence. Direct JMAP imports into the kernel account bypass the receiving checks. Wakeup and host completion callbacks use direct JMAP writes to their dedicated folder; see the [mail-service requirements](../docs/running.md#mail-service).

For [mail retention](../docs/running.md#data-and-retention), Ivenna moves retired communication copies and unreferenced history to Trash, and Stalwart controls their expiry. The example plan sets `DataRetention.expungeTrashAfter` to `2592000000` milliseconds (30 days), applying to Trash and Junk across all accounts. See Stalwart's [mail retention](https://stalw.art/docs/email/settings/maintenance/) and [storage maintenance](https://stalw.art/docs/storage/maintenance/) documentation for policy and space reclamation.

To apply the initial plan or later edits, stop the kernel, [load the instance configuration](#configuration), and run:

```sh
podman compose --env-file "$DEV_INSTANCE_DIR/.env" -f dev/compose.yaml -f dev/mail/setup.yaml up -d --wait mail
podman compose --env-file "$DEV_INSTANCE_DIR/.env" -f dev/compose.yaml -f dev/mail/setup.yaml run --rm --no-deps provision
```

The [setup override](mail/setup.yaml) starts Stalwart in recovery mode for the official CLI to apply the plan. `MAIL_SETUP_PASSWORD` controls the temporary setup credential; the administrator account in the plan supplies normal administration credentials. Applying the plan can replace account passwords.

The mail service remains in recovery mode until [normal startup](#starting-the-kernel) recreates it without the setup override. Later starts reuse its stored configuration; apply the plan again when that configuration changes.

The default local endpoints are:

| Interface | Address |
| --- | --- |
| JMAP session | `http://127.0.0.1:8088/jmap/session` |
| Authenticated SMTP submission | `127.0.0.1:2525` |
| Stalwart administration | `http://127.0.0.1:8088/admin` |

Published ports bind to loopback.

## Configuring memory

The memory preparation script creates or reuses the client and host keys under `$DEV_INSTANCE_DIR/memory/` and writes the `ivenna-memory` SSH target to its `config` file, matching the sample `MEMORY_SSH_CONFIG`. It pins the generated host key for verification. The default endpoint is `127.0.0.1:2222`.

With the [instance configuration loaded](#configuration), prepare the SSH connection and build the memory image from the current source:

```sh
dev/memory/prepare.sh
podman compose --env-file "$DEV_INSTANCE_DIR/.env" -f dev/compose.yaml build memory
```

Later starts reuse this image and connection. After changing the handler or container sources, follow the [memory rebuild steps](#memory). Changes to the local port or capacity follow the [service settings](#service-settings).

## Starting the kernel

After preparing the services, use a terminal with the [instance configuration loaded](#configuration) to start them with the kernel. The commands below start both local services. If only one is local, name it (`mail` or `memory`) in the Compose command; if both are external, skip that command.

```sh
podman compose --env-file "$DEV_INSTANCE_DIR/.env" -f dev/compose.yaml up -d --wait
zig build run
```

Compose waits for the mail health endpoint and memory SSH listener. It reuses the volumes and applies changed service settings when recreating containers. `zig build run` builds and runs the kernel. Keep it running in this terminal and use one kernel per mailbox.

From a second terminal, check reception at the default listener address:

```sh
curl --include http://127.0.0.1:8090/readyz
```

Continue when the response is `200 OK` with `X-Ivenna-Ready: true`. Adjust the URL if you changed the listener. See [service status](../docs/running.md#service-status-and-reception) for startup and reception behavior. Kernel diagnostics appear in its terminal; mail and memory diagnostics appear in the service logs.

## Sending a message

The operator account provides the `operator` correspondent ID for the local mailbox. Its sender address must use the domain of `MAIL_ADDRESS`; see [supported addressing](../docs/communication.md#current-email-addressing). With reception open, [load the instance configuration](#configuration) in a second terminal and submit through the local SMTP endpoint:

```sh
curl --url "smtp://127.0.0.1:${MAIL_SMTP_PORT:-2525}" --crlf \
  --user "$OPERATOR_MAIL_ADDRESS:$OPERATOR_MAIL_PASSWORD" \
  --mail-from "$OPERATOR_MAIL_ADDRESS" \
  --mail-rcpt "$MAIL_ADDRESS" \
  --upload-file - <<EOF
From: $OPERATOR_MAIL_ADDRESS
To: $MAIL_ADDRESS
Subject: French practice
Message-ID: <french-practice-$(date +%s)@ivenna.test>

Please remember that I am learning French and propose a practice plan.
EOF
```

With the supplied readiness policy installed, this command receives a `550` rejection when reception is closed or unreachable. The [mail setup](#configuring-mail) describes the policy's scope.

Read messages from Ivenna through a JMAP-capable client or mail API using the operator account and the service's JMAP session URL. Ivenna chooses whether and when to reply. See the [usage guide](../docs/usage.md) for continuing correspondence and interpreting responses.

## Stopping and restarting

Press `Ctrl+C` and wait for the kernel to exit. With the services running and configuration loaded, start it again with `zig build run`. The [restart guide](../docs/running.md#stopping-and-restarting) explains what survives, how running host commands stop, and how Ivenna continues interrupted work.

To remove the local middleware containers:

```sh
podman compose --env-file "$DEV_INSTANCE_DIR/.env" -f dev/compose.yaml down
```

The external volumes and private instance files remain in place. Use the [startup steps](#starting-the-kernel) to recreate the services and run the kernel again.

## Updating the kernel and middleware

Keep the same instance directory and [load its configuration](#configuration) for the commands below. Preparation preserves private copies of the examples; incorporate relevant changes from [.env.example](../.env.example) into the instance's `.env` and reload it.

### Kernel

The executable embeds the [model-facing resources](../docs/development.md#model-facing-resources) from their owning packages. Before running an updated executable against an existing mailbox, check the [history-format requirements](../docs/running.md#updating-the-executable). After editing code or embedded resources, stop the kernel and run `zig build run` to rebuild and restart it.

To use another source checkout, stop the previous kernel and follow the update steps from the new checkout's root, using the same instance directory and service volumes. Check history compatibility before resuming and rebuild memory if its sources changed. The new checkout becomes the default directory for host commands.

### Memory

The memory [Containerfile](../apps/memory/Containerfile) installs [memory.nu](../apps/memory/src/memory.nu). After changing the handler, container contents, or SSH entry point, stop the kernel, rebuild the image, and recreate the memory service:

```sh
podman compose --env-file "$DEV_INSTANCE_DIR/.env" -f dev/compose.yaml build --pull --no-cache memory
podman compose --env-file "$DEV_INSTANCE_DIR/.env" -f dev/compose.yaml up -d --wait memory
zig build run
```

For another memory deployment, update its handler and entry point as described in [memory service setup](../docs/running.md#memory-service).

### Mail

Incorporate changes from the [mail plan example](mail/provision.example.ndjson) into the private plan, keeping the deployment's credentials, addresses, and readiness URL. Apply the plan through [mail setup](#configuring-mail), then return to normal startup. Stalwart retains its account and policy configuration in the data volume; [config.json](mail/config.json) selects that store.

## Service settings

These settings configure the supplied local services in [dev/compose.yaml](compose.yaml). Stop the kernel before recreating a service.

| Variable | Purpose | Default when unset |
| --- | --- | --- |
| `DEV_INSTANCE_DIR` | Absolute directory for private development configuration and SSH files | Required |
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

If changing the mail HTTP port, update `MAIL_SESSION_URL` too. Account and server policy changes belong in the private provisioning plan; apply them through [local mail setup](#configuring-mail).

After changing service settings, reload `$DEV_INSTANCE_DIR/.env` and use [normal startup](#starting-the-kernel) to recreate affected containers. If changing `MEMORY_SSH_PORT`, first run `dev/memory/prepare.sh` again to update the SSH connection. Existing volumes and SSH keys remain in place. Changing `MAIL_VOLUME_NAME` or `MEMORY_VOLUME_NAME` selects different storage; create that volume before startup, and transfer existing data separately if needed. For mail transfers, follow the [history preservation requirements](../docs/running.md#backups-and-transfers).

Choosing another `DEV_INSTANCE_DIR` selects separate private files. The Compose project name remains `ivenna`; container names, ports, image names, and service volumes follow the settings above. Concurrent local deployments need distinct Compose project names, container names, ports, and data volumes.

For another memory deployment, configure capacity at its [service entry point](../docs/running.md#memory-service).

## Development data

| Location | Contents |
| --- | --- |
| Stalwart volume, `ivenna-mail` by default | Correspondence, callback inbox, working-history records, checkpoints, Trash, accounts, and Stalwart configuration |
| Memory volume, `ivenna-memory` by default | Shared memory rooms and entries |
| `$DEV_INSTANCE_DIR/.env` | Kernel and local service settings and credentials |
| `$DEV_INSTANCE_DIR/mail/provision.ndjson` | Private mail configuration plan |
| `$DEV_INSTANCE_DIR/memory/` | Local memory SSH configuration and keys |
| `<DATA_DIR>/host/` | Full host command output |

The example places host output under `$DEV_INSTANCE_DIR/data/`; `DATA_DIR` can select another location. Changing it leaves SSH files and middleware volumes in place. Container removal and recreation preserve the external volumes and private instance files. See [data and retention](../docs/running.md#data-and-retention) for the kernel's artifacts and the retention responsibilities of each store.
