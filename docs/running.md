# Running Ivenna

The Ivenna kernel connects to a model service, a mail service, and an SSH workspace for autonomous memory. This guide covers runtime requirements, configuration, startup, and data retention. For the supplied local environment, follow the [local development guide](../dev/README.md).

## Runtime requirements

Use a built `ivenna` executable, `/bin/sh`, and an OpenSSH client in the kernel's execution environment. See the [build instructions](development.md#repository-and-build) to build from source. Host commands run as the kernel's OS account and use the files and programs available in that environment.

The application uses the Responses adapter with DeepSeek as the default model service. Supply its API key, or configure a Responses-compatible endpoint and model through `LLM_BASE_URL` and `LLM_MODEL`. The kernel also needs access to the [mail service](#mail-service) and [memory service](#memory-service). The mail receiving boundary needs access to the kernel's [reception status](#service-status-and-reception).

## Configuration

The kernel reads its process environment. Supply the settings through the deployment's launcher or service manager. To apply changes, stop the kernel and start it with the updated environment.

Set connection addresses, identities, and paths for the chosen deployment. The table records the current executable's defaults.

| Variable | Purpose | Default when unset |
| --- | --- | --- |
| `LLM_API_KEY` | Model API key | Required |
| `LLM_BASE_URL` | Model API base URL | `https://api.deepseek.com` |
| `LLM_MODEL` | Model name | `deepseek-flash` |
| `LLM_MAX_OUTPUT_TOKENS` | Maximum generated tokens per response | `8192` |
| `SERVICE_ADDRESS` | HTTP health and reception-readiness listener | `0.0.0.0:8090` |
| `MAIL_SESSION_URL` | JMAP session URL | `http://127.0.0.1:8088/jmap/session` |
| `MAIL_ADDRESS` | Kernel address and sending identity; its domain resolves correspondent IDs | Required |
| `MAIL_USERNAME` | Mail login | Required for username/password authentication |
| `MAIL_PASSWORD` | Mail password | Required for username/password authentication |
| `MAIL_AUTHORIZATION` | Complete HTTP Authorization header | Unset; use username/password |
| `MAIL_POLL_INTERVAL_MS` | Delay between mail polls | `2000` |
| `MAX_PARALLEL_ATTENTION` | Maximum concurrently executing work sessions; core has a separate lane | `4` |
| `MAX_ATTENTION_CONTEXTS` | Maximum retained contexts, including the core; also sets each session's capacity | `32` |
| `CONTEXT_REQUEST_BYTES` | Maximum complete serialized ordinary model request | `65536` |
| `CONTEXT_COMPACTION_BYTES` | Maximum complete serialized summary request | `131072` |
| `HANDOVER_MAX_BYTES` | Maximum retained handover text | `8192` |
| `DATA_DIR` | Base directory for host command output in the kernel filesystem | `.ivenna` |
| `MEMORY_SSH_TARGET` | Memory SSH target | `ivenna-memory` |
| `MEMORY_SSH_CONFIG` | Dedicated SSH configuration file | Standard OpenSSH configuration |

`MAIL_AUTHORIZATION` takes precedence over username/password authentication. `SERVICE_ADDRESS` must contain a literal IP address and a nonzero port; keep the [mail readiness policy](#service-status-and-reception) aligned when changing it. Numeric kernel settings must be positive. `CONTEXT_COMPACTION_BYTES` must be at least `CONTEXT_REQUEST_BYTES`.

`MAX_PARALLEL_ATTENTION` and `MAX_ATTENTION_CONTEXTS` are independent. Parents waiting for children retain contexts without occupying execution slots. With `MAX_ATTENTION_CONTEXTS=1`, only the core fits and forking is unavailable. At capacity, pending mail remains available for later polling. See [session capacity](architecture.md#sessions-work-and-communication) for event limits and scheduling.

Request byte limits cover the whole serialized body, including instructions, tool definitions, history, complete incoming text, and encoded images. They do not estimate model tokens. If a single input cannot fit after context compaction, admission fails with `ContextBudgetExhausted` and the runtime stops. `HANDOVER_MAX_BYTES` also applies to the complete handover loaded at startup. See [bounded model context](architecture.md#bounded-model-context) for compaction and budget failures.

Relative `DATA_DIR` and `MEMORY_SSH_CONFIG` paths resolve from the kernel's startup directory.

## Mail service

Use a dedicated account with JMAP Mail and Submission capabilities and a sending identity matching `MAIL_ADDRESS`. The account needs Sent and Drafts folders and permission to create messages and update private keywords. Ivenna uses the Archive folder when present and creates it when missing, so that operation also needs permission.

Set the account's `MAIL_SESSION_URL`, `MAIL_ADDRESS`, and authentication settings in the kernel's environment. The adapter uses the domain of `MAIL_ADDRESS` to resolve correspondent IDs. Use separate correspondent accounts in that same domain to send messages to Ivenna and receive its outgoing mail. For `MAIL_ADDRESS=ivenna@ivenna.test`, the correspondent address `operator@ivenna.test` supplies the ID `operator`. Choose the domain for your deployment.

Addresses must use the [supported ASCII dot-atom local parts](communication.md#current-email-addressing) and an ASCII domain made of letters, digits, and hyphens in dot-separated labels. Labels begin and end with a letter or digit; a single-label domain is also supported. Domain matching ignores case, while correspondent IDs preserve case. Changing `MAIL_ADDRESS` to another domain changes how retained IDs resolve.

Install the [reception-readiness policy](#service-status-and-reception) on the service's receiving paths before using them for correspondence.

Correspondence and core state records share the mailbox. The [intake rules](#mail-intake) also apply to its existing mail. Configure service retention to preserve correspondence and core handovers needed for later continuation.

### Mail intake

The kernel reads ordinary unprocessed correspondence across mail folders, including Archive. Drafts and messages in Junk or Trash are excluded, along with the runtime's own outgoing and internal state records.

Incoming mail must have at least one From address, and every such address must map to a supported ID in the configured domain. Missing, cross-domain, or unsupported From addresses exclude the whole message from intake and recent received history, leaving its completion marker unchanged. The adapter presents the corresponding IDs and text as an observation.

Recent recollection also includes Ivenna's sent messages as separate records with their recipients. The adapter recognizes these records by its private outbound marker and Ivenna's sender address, and requires nonempty recipients in the configured domain. Integrations that bring outside material to Ivenna can submit it through an internal account with suitable context; the current adapter supports only same-domain correspondence.

Ivenna tracks processing with a private completion marker. Eligible mail without that marker is pending, including existing mail that has been read or archived. Review the mailbox before connecting it; reading, starring, or moving ordinary correspondence does not mark it as processed.

## Memory service

### SSH connection

Set `MEMORY_SSH_TARGET` to the memory service's SSH target. Set `MEMORY_SSH_CONFIG` to a dedicated file, or leave it unset to use standard OpenSSH configuration. SSH configuration controls the host, user, keys, timeout, and host key verification. The connection must work without interactive input.

### Handler and entry point

The current memory adapter invokes `/usr/local/bin/memory-shell` over SSH and exchanges JSON requests and replies with [memory.nu](../apps/memory/src/memory.nu). The service needs Nushell, ripgrep, fd, `flock`, and GNU or BusyBox `stat`. Use the Nushell version selected by the [Containerfile](../apps/memory/Containerfile), and install the programs on the `PATH` used by the memory shell.

Install the handler and prepare the SSH entry point using [memory-shell.sh](../apps/memory/memory-shell.sh) and [sshd_config](../apps/memory/sshd_config) as references. Choose the handler location for the service and set it in the shell wrapper. The supplied wrapper uses `/usr/local/lib/ivenna/memory.nu`.

### Workspace and locking

The shell wrapper selects the memory workspace through its working directory and holds a lock for each handler invocation. Choose the workspace and lock paths for the service. The supplied wrapper uses `/memory` for the workspace and `/run/ivenna/memory.lock` for the lock.

The SSH account needs read and write access to the workspace and lock. Create the lock's parent directory and lock file at service startup with the permissions needed by that account; [entrypoint.sh](../apps/memory/entrypoint.sh) provides an example. All handler processes sharing the workspace must use the same lock.

### Capacity

Set `MEMORY_CAPACITY_BYTES` in the memory service's environment, through its shell wrapper or the SSH server's `SetEnv`. It is a positive byte count and defaults to `1073741824` (1 GiB). See [memory space](memory.md#memory-space) for capacity behavior. Apply changes to the environment used by new handler invocations.

The [local development setup](../dev/README.md#configuring-memory) packages this service in a container and prepares its SSH connection.

## Starting the kernel

Prepare the configured services and supply the kernel's environment, then run the built executable from the directory chosen for host work. For example, with the executable installed at `/path/to/ivenna`:

```sh
cd /path/to/workspace
/path/to/ivenna
```

The kernel's startup directory becomes the default directory for host commands. The executable embeds its model-facing resources and can run independently of the source checkout.

Startup discovers the mail account and checks memory with a read-only space inspection. Both must succeed before Ivenna can run. Use one kernel per mailbox. Check [reception readiness](#service-status-and-reception) before following the [usage guide](usage.md) to send a message. Diagnostics are written to the kernel's standard error; service diagnostics follow each service's configuration.

## Service status and reception

`SERVICE_ADDRESS` selects the kernel's HTTP listener and defaults to `0.0.0.0:8090`. While the listener is running, it exposes:

| Endpoint | Response |
| --- | --- |
| `GET /healthz` | `200 OK` for listener health |
| `GET /readyz` | `200 OK` with `X-Ivenna-Ready: true` when reception is open; otherwise `503 Service Unavailable` |

Reception opens after startup checks and core context preparation. It closes when the runtime stops or fails. These endpoints report lifecycle state; they do not probe mail or memory on each request. Once the process has exited, its listener is also gone. For a listener reachable at `127.0.0.1:8090`, check the current state with:

```sh
curl --include http://127.0.0.1:8090/readyz
```

Configure the mail receiving boundary to check the readiness header at an address it can reach and reject incoming traffic when the header is absent, including when the endpoint cannot be reached. Apply the policy to every receiving address and delivery path used for correspondence. The [local Stalwart setup](../dev/README.md#configuring-mail) demonstrates an SMTP recipient check.

Readiness describes the kernel's reception state when queried. It reserves no processing capacity, and the runtime can stop after a successful check or accepted delivery. The kernel continues to read [ordinary unprocessed mail](#mail-intake) already present in its mailbox.

With SMTP, a recipient rejection reaches the sending server during that delivery attempt. A normal mail client may already have submitted to its own server, which handles the delivery result. Connection failures can also lead that server to queue and retry mail. See SMTP's [delivery responsibilities](https://www.rfc-editor.org/rfc/rfc5321.html#section-4.2.5) and [retry behavior](https://www.rfc-editor.org/rfc/rfc5321.html#section-4.5.4.1).

## Stopping and restarting

Send `SIGTERM`, or press `Ctrl+C` when running in a terminal, to close reception and wait for the kernel's workers to end. Communication or memory infrastructure failures and errors propagated by execution also stop the whole kernel. Diagnose the failure from its diagnostics and restore any unavailable services before restarting.

When an incoming message fails admission with `ContextBudgetExhausted`, it remains unprocessed. Before restarting, review the [request budgets](#configuration) and [eligible pending correspondence](#mail-intake). Adjust the budgets or remove a message that cannot fit from eligible intake as appropriate; restarting alone does not resolve the budget failure.

An interrupted operation may already have changed files, memory, or mail. Inspect uncertain effects before restarting. Start the executable again with the same deployment configuration and data. Ivenna reconstructs its understanding from retained material; see [after interruption](usage.md#after-interruption) for what continuation means.

## Data and retention

The deployment chooses mailbox storage, the memory workspace, and the host output directory independently:

| Location | Contents |
| --- | --- |
| Configured JMAP mailbox | Correspondence, core handovers, and private processing markers |
| Configured memory workspace | Shared memory rooms and entries |
| `<DATA_DIR>/host/<session_id>/` | Full stdout and stderr from host commands |

`DATA_DIR` selects the base directory for host output in the kernel's filesystem. The kernel creates it with private permissions when missing. Changing it selects where new output files are written; it does not move existing files, mailbox storage, memory, or SSH configuration. Provisioning files, credentials, and SSH keys belong to deployment configuration. The [local development data reference](../dev/README.md#development-data) lists the Compose volumes and files used by that setup.

Host output files remain available after the command and work session end. Retained material can refer to their paths, so preserve files still needed for continued work. Automatic output cleanup is not implemented.

Core handovers are self-addressed state records stored in the mailbox's Archive folder when the core context is compacted. Work sessions compact in memory. Saving a handover or releasing working context leaves correspondence in its existing folders. Manage mailbox capacity through retention and deletion; see [mail retention](architecture.md#mail-retention).

## Optional host tools

Host commands use the kernel's startup directory by default and inherit its environment. Install additional programs in the kernel's execution environment and make them executable by its OS account. Include their locations in `PATH` or invoke them by path. Restart the kernel to apply startup environment changes.
