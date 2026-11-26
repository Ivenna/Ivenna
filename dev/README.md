# Local development

This setup runs the kernel from the source checkout, with mail and memory services managed by [compose.yaml](compose.yaml). A private instance directory holds configuration and SSH keys; external service volumes hold mail and memory. Run the commands from the repository root. For runtime requirements and other service arrangements, see the [running guide](../docs/running.md).

## Prerequisites

Install the Zig version in [`.zig-version`](../.zig-version), an OpenSSH client, and `curl`.

Use [Docker Compose](https://docs.docker.com/compose/) or [Podman Compose](https://docs.podman.io/en/latest/markdown/podman-compose.1.html) for the mail and memory services. The commands below use Podman. See the [development guide](../docs/development.md) for build conventions and the [testing guide](../docs/testing.md) for automated checks that run directly on the host.

## Configuration

Choose an absolute path for the private instance directory and prepare it. This example keeps it outside the source checkout:

```sh
export DEV_INSTANCE_DIR="$HOME/ivenna-dev"
dev/prepare.sh
```

The preparation script copies [.env.example](../.env.example) to `$DEV_INSTANCE_DIR/.env` and the [mail plan example](mail/provision.example.ndjson) to `$DEV_INSTANCE_DIR/mail/provision.ndjson`. Running it again preserves existing private files.

In the instance's `.env`, set `LLM_API_KEY` to your DeepSeek API key. If you customize the kernel or operator account, use the same address and credentials in `.env` and the private mail plan. The sample registers the operator mailbox in `MAIL_CORRESPONDENTS` so Ivenna can reply to it. See [configuring mail](#configuring-mail).

The example stores kernel files in `$DEV_INSTANCE_DIR/data` and uses `$DEV_INSTANCE_DIR/memory/config` for `MEMORY_SSH_CONFIG`. To use other services, configure their connections and prepare the services you run locally. See [mail service setup](../docs/running.md#mail-service) and [memory service setup](../docs/running.md#memory-service).

To enable optional web page retrieval, set `DEEPSEEK_API_KEY` in the same file. See [web page access](../docs/running.md#web-page-access).

In each terminal used for development commands, export your chosen `DEV_INSTANCE_DIR` and load its `.env` file. Reload it after editing its values:

```sh
export DEV_INSTANCE_DIR="$HOME/ivenna-dev"
set -a
. "$DEV_INSTANCE_DIR/.env"
set +a
```

The kernel and memory preparation script use the exported environment. If you remove an override from `.env`, also `unset` that variable in any shell where you exported it. The Compose commands select the instance configuration with `--env-file`. See [kernel settings](../docs/running.md#configuration) and [local service settings](#service-settings) for defaults.

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
| `operator@ivenna.test` | Correspond with Ivenna | `operator-local-password` |
| `admin@ivenna.test` | Stalwart administration | `admin-local-password` |

The plan requires authenticated SMTP submission. `MtaStageAuth.mustMatchSender` checks that the account may use the SMTP envelope sender. At `DATA`, the `ivenna-sender` script selected by `MtaStageData` requires exactly one From address matching that sender, ignoring case. See Stalwart's [sender verification](https://stalw.art/docs/mta/inbound/auth/#sender-verification) and [From-header example](https://stalw.art/docs/sieve/examples/#require-the-from-header-to-match-the-sender-of-authenticated-mail).

The plan's `ivenna-ready` script runs during SMTP `RCPT` handling through its `MtaStageRcpt` rule. Set the script's recipient to Ivenna's address and its readiness URL to an endpoint reachable from the mail container. The example uses `ivenna@ivenna.test` and `http://host.containers.internal:8090/readyz`; Compose maps that host name to the host. Keep the address and URL aligned with `MAIL_ADDRESS` and `SERVICE_ADDRESS`.

The script rejects that recipient with `550` when the readiness header is absent or the endpoint cannot be reached. The example defines one receiving address and disables subaddressing. Adding aliases or another path to the account requires a policy that gates those addresses too. See [reception readiness](../docs/running.md#service-status-and-reception) for the status contract.

Use the SMTP submission path for correspondence. Direct JMAP imports into the kernel account bypass the receiving checks. Wakeup and host completion callbacks use direct JMAP writes to their dedicated folder; see the [mail-service requirements](../docs/running.md#mail-service).

For [mail retention](../docs/running.md#data-and-retention), Ivenna moves retired communication copies and unreferenced history to Trash, and Stalwart controls their expiry. The example plan sets `DataRetention.expungeTrashAfter` to `2592000000` milliseconds (30 days), applying to Trash and Junk across all accounts. See Stalwart's [mail retention](https://stalw.art/docs/email/settings/maintenance/) and [storage maintenance](https://stalw.art/docs/storage/maintenance/) documentation for policy and space reclamation.

### Sizing Stalwart for working history

For text exchanges and uploaded file references, start with Stalwart's default size limits, which the example plan inherits. If a round can include a large inline image, allow for the encoded image and the other tool results in that round. See [working history limits](../docs/running.md#working-history-limits).

When a regular account writes a history message with JMAP `Email/set`, Stalwart v1.0.2 checks both the request and the message it creates. These limits apply server-wide. [JMAP request handler](https://github.com/stalwartlabs/stalwart/blob/v1.0.2/crates/http/src/request.rs#L171-L187) · [Email part-size check](https://github.com/stalwartlabs/stalwart/blob/v1.0.2/crates/jmap/src/email/set.rs#L748-L790) · [Stalwart message limits](https://stalw.art/docs/email/settings/jmap/)

| Setting | What must fit | v1.0.2 default (bytes) |
| --- | --- | ---: |
| `Jmap.maxRequestSize` | Complete JSON request, which can contain several records | 10,000,000 |
| `Jmap.maxUploadSize` | Incoming HTTP body, including JMAP JSON requests | 50,000,000 |
| `Email.maxAttachmentSize` | Total size of message parts, including the history text | 50,000,000 |
| `Email.maxMessageSize` | Complete MIME message | 75,000,000 |

A sizing test on v1.0.2 used one 32 MiB inline image part filled with bytes requiring four-character escapes such as `\xff`. Escaping each backslash for JSON took a fifth byte. The history text occupied about 128 MiB, the JMAP request 160 MiB, and the stored MIME message 133 MiB.

Those measurements bound one record under each Stalwart default:

| Representation | Worst-case bytes per image byte | Original image bytes at the default request limit | Encoded size for those image bytes |
| --- | ---: | ---: | ---: |
| History text | 4 | 2,000,000 | 8,000,000 |
| JMAP request | 5 | 2,000,000 | 10,000,000 |
| MIME message | about 4.2 | 2,000,000 | about 8,300,000 |

`Jmap.maxRequestSize` is the binding default: 10,000,000 / 5 = 2,000,000 original image bytes. This is a theoretical maximum with no margin: the JMAP envelope, message headers, other text, file references, and the encoding of everything else also count toward those limits. That is why the 8,000,000 bytes of history text fit within `Email.maxAttachmentSize` (50,000,000), and the about 8,300,000-byte MIME message fits within `Email.maxMessageSize` (75,000,000), but a real record must stay below 2,000,000 image bytes.

The kernel bounds the inline image bytes in one history record with `HISTORY_INLINE_IMAGE_BYTES`, 1 MiB by default. At the ratios above, that needs at most 4 MiB of history text, 5 MiB in the JMAP request, and about 4.2 MiB in the MIME message. Stalwart's default `Jmap.maxRequestSize` of 10,000,000 bytes therefore leaves about half of the request for the rest of the record. When a round exceeds the kernel limit, the kernel replaces each inline image with a text placeholder that gives its byte length and keeps the rest of the round. It does not reject the round or send the image. The limit constrains images only; non-image text, reasoning, and tool-call arguments also expand in the request, so the image limit alone does not guarantee that a record fits `Jmap.maxRequestSize`.

The example plan raises the server limits so a deployment can retain the content layer's maximum 32 MiB inline image per round when it also raises `HISTORY_INLINE_IMAGE_BYTES` to `33554432`. The sample applies to raw `.data` bytes. A data URL counts by its complete encoded length, so a 32 MiB Base64 data URL needs about 44.7 MB of image budget and this sample would replace it with a text placeholder. It includes these lines:

```jsonl
{"@type":"update","object":"Jmap","value":{"maxRequestSize":201326592,"maxUploadSize":201326592}}
{"@type":"update","object":"Email","value":{"maxAttachmentSize":167772160,"maxMessageSize":201326592}}
```

The measured 32 MiB image needs about 128 MiB of history text, 160 MiB of JMAP request, and 133 MiB of MIME message. The 160 MiB attachment limit holds the history text and the other message parts; the 192 MiB request and message limits leave room for their protocol and MIME overhead. Keep `HISTORY_INLINE_IMAGE_BYTES` at or below the value these server limits can carry.

After [normal startup](#starting-the-kernel), check the two JMAP limits advertised to the kernel account.

```sh
curl --fail --silent --show-error --user "$MAIL_USERNAME:$MAIL_PASSWORD" "$MAIL_SESSION_URL" |
  jq '.capabilities["urn:ietf:params:jmap:core"] | {maxSizeRequest, maxSizeUpload}'
```

### Applying the mail plan

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
zig build run -- serve
```

Compose waits for the mail health endpoint and memory SSH listener. It reuses the volumes and applies changed settings when recreating containers. The second command builds `zig-out/bin/ivenna` and runs the kernel in this terminal.

From a second terminal, check reception at the default listener address:

```sh
curl --include http://127.0.0.1:8090/readyz
```

Continue when the response is `200 OK` with `X-Ivenna-Ready: true`. Adjust the URL if you changed the listener. See [service status](../docs/running.md#service-status-and-reception) for startup and reception behavior. The kernel terminal shows [JMAP request failures](../docs/running.md#when-a-mail-request-fails). The mail and memory services write their own logs.

## Sending a message

With reception open, [load the instance configuration](#configuration) in a second terminal and submit a message from the operator account through the local SMTP endpoint.

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

## Trying a channel

Send this request using the [mail example](#sending-a-message).

> Delegate this check to an activity. Ask it to open a channel named `task-input` for short test messages, then send `first` before starting a receiver.
>
> In that activity, use `run_host_shell` with `yield_ms: 0` to start `"$IVENNA" receive CHANNEL_ID --follow`, substituting the complete channel ID. Send `first` again and read the output with `continue_host_shell`. Then send and read `second`. If a send reports `channel_would_block`, check that the receiver is still running and give it time to request its next read before retrying.
>
> After reading both messages, have the activity close the channel and collect the receiver's exit status. Report the send results, command output, and exit status.

Expect `channel_would_block` before the receiver starts, then two `accepted` results and two JSON `message` records in order. The receiver should exit with status 0 after the channel closes. See the [channel interface](../docs/communication.md#channels).

## Trying a subscription listener

In a second terminal at the repository root, [load the same instance environment](#configuration) to set `DATA_DIR`, then point `IVENNA` at the executable built at startup.

```sh
export IVENNA="$PWD/zig-out/bin/ivenna"
```

To run the listener independently, follow the [deployment guide](../docs/running.md#subscription-listeners).

Ask Ivenna to [register a subscription](../docs/attention.md#subscriptions) and give you its complete ID. Use that ID in place of the example.

```sh
subscription_id='release-watch-1'
"$IVENNA" subscription inspect "$subscription_id"
```

The result shows the receiving focus and saved cursor. Use the same ID to [publish a test observation](../docs/subscriptions.md#publish-an-observation).

## Stopping and restarting

Press `Ctrl+C` and wait for the kernel to exit. With the services running and configuration loaded, start it again with `zig build run -- serve`. The [restart guide](../docs/running.md#stopping-and-restarting) explains what survives, how running host commands stop, and how Ivenna continues interrupted work.

To remove the local middleware containers:

```sh
podman compose --env-file "$DEV_INSTANCE_DIR/.env" -f dev/compose.yaml down
```

The external volumes and private instance files remain in place. Use the [startup steps](#starting-the-kernel) to recreate the services and run the kernel again.

## Updating the kernel and middleware

For compatible updates, keep the same instance directory. If you edit its `.env`, [reload the configuration](#configuration) in the shell that will launch the kernel.

### Kernel

Check the [upgrade guide](../docs/upgrading.md) for changes to defaults, stored data, and caller interfaces.

After editing code or [embedded resources](../docs/development.md#model-facing-resources), stop the kernel and run `zig build run -- serve` to rebuild and restart it. To use another source checkout, run the update steps from its root and point independent channel receivers and subscription listeners at that checkout's `zig-out/bin/ivenna`. The kernel starts file browsing and host commands from that checkout.

### Memory

The memory [Containerfile](../apps/memory/Containerfile) installs [memory.nu](../apps/memory/src/memory.nu). After changing the handler, container contents, or SSH entry point, stop the kernel, rebuild the image, and recreate the memory service:

```sh
podman compose --env-file "$DEV_INSTANCE_DIR/.env" -f dev/compose.yaml build --pull --no-cache memory
podman compose --env-file "$DEV_INSTANCE_DIR/.env" -f dev/compose.yaml up -d --wait memory
zig build run -- serve
```

For another memory deployment, update its handler and entry point as described in [memory service setup](../docs/running.md#memory-service).

### Mail

Incorporate changes from the [mail plan example](mail/provision.example.ndjson) into the private plan, keeping the deployment's credentials, addresses, and readiness URL. [Apply the mail plan](#applying-the-mail-plan), then return to normal startup. Stalwart retains its account and policy configuration in the data volume; [config.json](mail/config.json) selects that store.

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

If changing the mail HTTP port, update `MAIL_SESSION_URL` too. For account and server policy changes, [apply the private mail plan](#applying-the-mail-plan).

After changing service settings, reload `$DEV_INSTANCE_DIR/.env` and use [normal startup](#starting-the-kernel) to recreate affected containers. If changing `MEMORY_SSH_PORT`, first run `dev/memory/prepare.sh` again to update the SSH connection. Existing volumes and SSH keys remain in place. Changing `MAIL_VOLUME_NAME` or `MEMORY_VOLUME_NAME` selects different storage; create that volume before startup, and transfer existing data separately if needed. For mail transfers, follow the [history preservation requirements](../docs/running.md#backups-and-transfers).

Choosing another `DEV_INSTANCE_DIR` selects separate private files. The Compose project name remains `ivenna`; container names, ports, image names, and service volumes follow the settings above. Concurrent local deployments need distinct Compose project names, container names, ports, and data volumes.

For another memory deployment, configure capacity at its [service entry point](../docs/running.md#memory-service).

## Development data

| Location | Contents |
| --- | --- |
| Stalwart volume, `ivenna-mail` by default | Mail accounts, the kernel's mailbox data, and Stalwart configuration |
| Memory volume, `ivenna-memory` by default | Shared memory rooms and entries |
| `$DEV_INSTANCE_DIR/.env` | Kernel and local service settings and credentials |
| `$DEV_INSTANCE_DIR/mail/provision.ndjson` | Private mail configuration plan |
| `$DEV_INSTANCE_DIR/memory/` | Local memory SSH configuration and keys |
| `$DEV_INSTANCE_DIR/data/` | Host output and the instance database. See [kernel data locations](../docs/running.md#data-and-retention). |

Container replacement preserves the external volumes and private instance files. To move the instance, follow the [backup and transfer procedures](../docs/running.md#backups-and-transfers).
