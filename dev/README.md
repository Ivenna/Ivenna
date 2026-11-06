# Local development

This setup runs the kernel from the source checkout, with mail and memory services managed by [compose.yaml](compose.yaml). Run the commands from the repository root. For runtime requirements and other service arrangements, see the [running guide](../docs/running.md).

## Prerequisites

Install the Zig version in [`.zig-version`](../.zig-version), an OpenSSH client, and `curl`. Zig builds the kernel; OpenSSH connects to memory and prepares its keys; `curl` checks reception and sends the example message.

Use [Docker Compose](https://docs.docker.com/compose/) or [Podman Compose](https://docs.podman.io/en/latest/markdown/podman-compose.1.html) for the middleware. The commands below use Podman. The [development guide](../docs/development.md) covers build conventions and validation.

## Configuration

Create the configuration file:

```sh
cp -n .env.example .env
```

Set `LLM_API_KEY` and configure the mail and memory connections. The sample settings match the local services below. To use another [mail service](../docs/running.md#mail-service) or [memory workspace](../docs/running.md#memory-service), configure those connections and prepare only the services you run locally.

The kernel authenticates with `MAIL_*`; the [message example](#sending-a-message) uses `OPERATOR_MAIL_ADDRESS` and `OPERATOR_MAIL_PASSWORD` for a separate account. Keep local account credentials aligned with the private [mail provisioning plan](#configuring-mail).

The kernel, Compose, and memory preparation script use the exported configuration. Load `.env` in each terminal used for these commands, and reload it after editing its values:

```sh
set -a
. ./.env
set +a
```

Git ignores `.env`, `dev/mail/provision.ndjson`, and the default `.ivenna/` directory. The kernel reads the exported environment; it does not load `.env` itself. When removing a variable from `.env`, also unset its previously exported value or start a new terminal. See [kernel settings](../docs/running.md#configuration) and [local middleware settings](#service-settings) for defaults and how to apply changes.

## Preparing service storage

Before provisioning or starting local services for the first time, create their external data volumes:

```sh
podman volume create "${MAIL_VOLUME_NAME:-ivenna-mail}"
podman volume create "${MEMORY_VOLUME_NAME:-ivenna-memory}"
```

Create only the corresponding volume when using one local service. Existing setups reuse their volumes. The [local data reference](#development-data) lists their contents and the SSH files retained outside them.

When replacing independently managed local middleware with this Compose project, stop the kernel and remove the old containers before the preparation below. Retain the named volumes and `.ivenna/dev-memory/` to reuse their data and SSH keys.

## Configuring mail

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

The plan also defines the `ivenna-ready` script and its `MtaStageRcpt` rule. Set the script's recipient to Ivenna's address and its readiness URL to an endpoint reachable from the mail container. The example uses `ivenna@ivenna.test` and `http://host.containers.internal:8090/readyz`; Compose maps that host name to the host. Keep the address and URL aligned with `MAIL_ADDRESS` and `SERVICE_ADDRESS`. See [reception readiness](../docs/running.md#service-status-and-reception) for the status interface.

When updating a private plan, preserve the accounts, credentials, and domains in use. Keep the readiness gate for Ivenna's address and the domain's disabled `subAddressing` setting. Restarting a container does not update this stored policy.

To apply the initial plan or later edits, stop the kernel, load the updated `.env`, and run:

```sh
podman compose -f dev/compose.yaml -f dev/mail/setup.yaml up -d --wait mail
podman compose -f dev/compose.yaml -f dev/mail/setup.yaml run --rm --no-deps provision
```

The [setup override](mail/setup.yaml) starts Stalwart in recovery mode for the official CLI to apply the plan. `MAIL_SETUP_PASSWORD` controls the temporary setup credential; the administrator account in the plan supplies normal administration credentials. Applying the plan can replace account passwords.

The mail service remains in recovery mode until [normal startup](#starting-the-kernel) recreates it without the setup override. Later starts reuse its stored configuration; apply the plan again when that configuration changes.

The default local endpoints are:

| Interface | Address |
| --- | --- |
| JMAP session | `http://127.0.0.1:8088/jmap/session` |
| Authenticated SMTP submission | `127.0.0.1:2525` |
| Stalwart administration | `http://127.0.0.1:8088/admin` |

Published ports bind to loopback. The plan requires authenticated submission with a matching sender; its listener, spam, and rate policies are defined in the plan. Stalwart stores mail, accounts, and configuration in the external volume, which remains after the Compose containers are removed.

The supplied readiness script rejects Ivenna's recipient with `550` when the readiness header is absent or the endpoint cannot be reached. The example defines one receiving address and disables subaddressing. Adding aliases or another path to the account requires a policy that gates those addresses too.

This gate runs during SMTP `RCPT` handling. JMAP imports and delivery between accounts through the same server's JMAP interface bypass it. Use the gated SMTP path for external messages. Readiness is a precheck; the kernel can stop after a successful check or accepted delivery.

## Configuring memory

Prepare the SSH connection and build the memory image from the current source:

```sh
dev/memory/prepare.sh
podman compose -f dev/compose.yaml build memory
```

The preparation script creates or reuses the client and host keys under `.ivenna/dev-memory/` and writes the `ivenna-memory` SSH target to its `config` file, matching the sample `MEMORY_SSH_CONFIG`. It pins the generated host key for verification. The default endpoint is `127.0.0.1:2222`.

Later starts reuse this image and connection. After changing the handler or container sources, follow the [memory rebuild steps](#updating-the-kernel-and-middleware). Changes to the local port or capacity follow the [middleware settings](#service-settings).

## Starting the kernel

After preparing the services, load the configuration and start them with the kernel. The commands below start both local services. If only one is local, name it (`mail` or `memory`) in the Compose command; if both are external, skip that command.

```sh
set -a
. ./.env
set +a
podman compose -f dev/compose.yaml up -d --wait
zig build run
```

Compose waits for the mail health endpoint and memory SSH listener. It reuses the volumes and applies changed service settings when recreating containers. `zig build run` builds and runs the kernel. Keep it running in this terminal and use one kernel per mailbox.

From a second terminal, check reception at the default listener address:

```sh
curl --include http://127.0.0.1:8090/readyz
```

Continue when the response is `200 OK` with `X-Ivenna-Ready: true`. Adjust the URL if you changed the listener. See [service status](../docs/running.md#service-status-and-reception) for startup and reception behavior. Kernel diagnostics appear in its terminal; mail and memory diagnostics appear in the service logs.

## Sending a message

The operator account provides a correspondent for the local mailbox. With reception open, load the configuration in a second terminal and submit through the local SMTP endpoint:

```sh
set -a
. ./.env
set +a
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

Read Ivenna's outgoing messages through a JMAP-capable client or mail API using the operator account and the service's JMAP session URL. Ivenna chooses whether and when to send a message; SMTP acceptance alone does not require a reply. See the [usage guide](../docs/usage.md) for sending requests and continuing correspondence.

## Stopping and restarting

Press `Ctrl+C` to stop the kernel and wait for its workers. Before restarting after an interruption, inspect uncertain effects as described in the [restart guidance](../docs/running.md#stopping-and-restarting). With the services running and configuration loaded, start the kernel again with `zig build run`.

To remove the local middleware containers while retaining mail, memory, and SSH keys:

```sh
podman compose -f dev/compose.yaml down
```

Use the [startup steps](#starting-the-kernel) to recreate the services and run the kernel again.

## Updating the kernel and middleware

### Kernel

The executable embeds the [model-facing resources](../docs/development.md#model-facing-resources) from their owning packages. After editing code or these resources, stop the kernel and run `zig build run` to rebuild and restart it. Restart follows the [continuity contract](../docs/architecture.md#startup-and-interruption).

### Memory

The memory [Containerfile](../apps/memory/Containerfile) installs [memory.nu](../apps/memory/src/memory.nu). After changing the handler, container contents, or SSH entry point, stop the kernel, rebuild the image, and recreate the memory service:

```sh
podman compose -f dev/compose.yaml build --pull --no-cache memory
podman compose -f dev/compose.yaml up -d --wait memory
zig build run
```

This retains the external memory volume and SSH keys. The build context includes only the image sources selected by [`.dockerignore`](../.dockerignore). For another workspace, update its handler and entry point as described in [memory service setup](../docs/running.md#memory-service).

### Mail

Stalwart's account and policy configuration lives in its data store; [config.json](mail/config.json) selects that store. Apply provisioning-plan changes through [mail setup](#configuring-mail), then return to normal startup. Container recreation retains the stored configuration and mail.

## Service settings

These settings configure the supplied local services in [dev/compose.yaml](compose.yaml). Stop the kernel before recreating a service.

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

If changing the mail HTTP port, update `MAIL_SESSION_URL` too. Account and server policy changes belong in the private provisioning plan; apply them through [local mail setup](#configuring-mail).

After changing service settings, reload `.env` and use [normal startup](#starting-the-kernel) to recreate affected containers. If changing `MEMORY_SSH_PORT`, first run `dev/memory/prepare.sh` again to update the SSH connection. Existing volumes and SSH keys remain in place. Changing `MAIL_VOLUME_NAME` or `MEMORY_VOLUME_NAME` selects different storage; create that volume before startup, and transfer existing data separately if needed.

Source changes inside the memory image require a [rebuild](#updating-the-kernel-and-middleware). For another memory deployment, configure capacity at its [service entry point](../docs/running.md#memory-service).

## Development data

| Location | Contents |
| --- | --- |
| Stalwart volume, `ivenna-mail` by default | Mail, handovers, accounts, and Stalwart configuration |
| Memory volume, `ivenna-memory` by default | Shared memory rooms and entries |
| `.env` | Kernel and local service settings and credentials |
| `dev/mail/provision.ndjson` | Private mail configuration plan |
| `.ivenna/dev-memory/` | Local memory SSH configuration and keys |

The preparation script and Compose use `.ivenna/dev-memory/` under the repository root independently of `DATA_DIR`. Changing `DATA_DIR` leaves these files and the middleware volumes in place. See [data and retention](../docs/running.md#data-and-retention) for the kernel's artifacts and the retention responsibilities of each store.
