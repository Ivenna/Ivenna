# Running Ivenna

The Ivenna kernel connects to a model service, a mail service, and an SSH workspace for autonomous memory. This guide covers installation, configuration, startup, and data retention. For the supplied local environment, follow the [local development guide](../dev/README.md).

## Runtime requirements

Run `ivenna` on Linux with abstract Unix socket support. The kernel's execution environment needs `/bin/sh` and an OpenSSH client.

The core and activities can read regular files and list directories wherever the kernel's OS account has access. Choose the account and filesystem mounts accordingly. Host commands run as the same account.

Terminal mode additionally requires Linux 5.3 or newer with `pidfd_open`, `pidfd_send_signal`, and `TIOCGPTPEER` available, a working `/dev/ptmx` backed by devpts, and util-linux `setsid` at `/usr/bin/setsid`. It enumerates processes under `/proc` to find and clean up its session's foreground and background jobs. Batch and pipe modes do not require this terminal transport.

Set `LLM_API_KEY` to a DeepSeek API key. The kernel uses the DeepSeek Responses API for inference and the Files API for [file input](content.md#complete-files).

The kernel also needs access to the [mail service](#mail-service) and [memory service](#memory-service). The mail receiving boundary needs access to the kernel's [reception status](#service-status-and-reception).

## Installing the executable

Use the `.tar.gz` archive, `.sha256` checksum, and `.json` build record with the same base name. For a tagged release, download these files from [GitHub Releases](https://github.com/Ivenna/Ivenna/releases).

Check that the architecture in the build record's `target` matches `uname -m` on the host. Use `getconf GNU_LIBC_VERSION` to check that the installed glibc is at least `glibc_min`. [Release package format](releasing.md#release-packages)

From the directory containing the package files, set `package` to their shared base name. Verify the checksum before extracting the archive.

```sh
package=ivenna-x86_64-linux-gnu-v0.1.0
sha256sum -c "$package.sha256" && tar -xzf "$package.tar.gz"
```

Before replacing an existing binary, follow the [executable update steps](#updating-the-executable). Install the extracted `ivenna` at the path your launcher uses.

```sh
install -m 755 ivenna /path/to/ivenna
```

To build the executable from source, follow the [build instructions](development.md#repository-and-build).

## Configuration

The kernel reads its process environment at startup. Supply settings through the deployment's launcher or service manager. To use an environment file, export its values before launching, as shown in the [local configuration steps](../dev/README.md#configuration). Apply changes by restarting the kernel with the updated environment.

Set connection addresses, identities, and storage paths for the chosen deployment. The table lists required settings and the current executable's defaults.

| Variable | Purpose | Default when unset |
| --- | --- | --- |
| `LLM_API_KEY` | DeepSeek API key for inference and file uploads | Required |
| `LLM_BASE_URL` | API base URL for inference and file uploads | `https://api.deepseek.com` |
| `LLM_MODEL` | DeepSeek model name | `deepseek-flash` |
| `LLM_MAX_OUTPUT_TOKENS` | Maximum output tokens per response, including reasoning tokens | `65536` |
| `LLM_REQUEST_TIMEOUT_MS` | Time limit for one inference attempt or one file upload, including upload negotiation | `600000` (10 minutes) |
| `LLM_CORE_REASONING_EFFORT` | Reasoning effort for ordinary core requests | `low` |
| `LLM_ACTIVITY_REASONING_EFFORT` | Reasoning effort for ordinary activity-session requests | `max` |
| `LLM_COMPACTION_REASONING_EFFORT` | Reasoning effort used to write a handover summary | `max` |
| `DEEPSEEK_API_KEY` | DeepSeek Fetch credential for [web page access](#web-page-access) | Web page retrieval disabled |
| `CONTEXT_COMPACT_AT_TOKENS` | Input-token threshold for compaction | `262144` |
| `CONTEXT_COMPACT_AT_BYTES` | Fallback threshold for compaction, in encoded request bytes | `1048576` (1 MiB) |
| `CONTEXT_OBSERVATION_BATCH_BYTES` | Target for the encoded bytes a batch of observations adds to a request | `1048576` (1 MiB) |
| `SERVICE_ADDRESS` | HTTP health and reception-readiness listener | `0.0.0.0:8090` |
| `MAIL_SESSION_URL` | URL for [JMAP session discovery](#mail-service) | `http://127.0.0.1:8088/jmap/session` |
| `MAIL_ADDRESS` | Kernel mailbox address and sending identity | Required |
| `MAIL_CORRESPONDENTS` | Comma-separated [mailbox addresses for outgoing correspondence](#outgoing-correspondents) | No registered recipients |
| `MAIL_USERNAME` | Mail login | Required for username/password authentication |
| `MAIL_PASSWORD` | Mail password | Required for username/password authentication |
| `MAIL_AUTHORIZATION` | Complete HTTP Authorization header | Unset; use username/password |
| `MAIL_POLL_INTERVAL_MS` | Milliseconds between checks for mail and subscription reports | `2000` |
| `MAX_SESSIONS` | Maximum registered session identities, including sleeping sessions and the core | `128` |
| `MAX_PENDING_EVENTS` | Maximum ordinary accepted events buffered per session | `64` |
| `MAX_HOST_COMMANDS` | Maximum live host commands across all activity sessions | `8` |
| `DATA_DIR` | Persistent directory for instance state and host command output | Required |
| `MEMORY_SSH_TARGET` | Memory SSH target | `ivenna-memory` |
| `MEMORY_SSH_CONFIG` | Dedicated SSH configuration file | Standard OpenSSH configuration |

`MAIL_AUTHORIZATION` takes precedence over username/password authentication. `SERVICE_ADDRESS` must contain a literal IP address and a nonzero port; keep the [mail readiness policy](#service-status-and-reception) aligned when changing it.

Numeric kernel settings must be positive. Relative `DATA_DIR` and `MEMORY_SSH_CONFIG` paths resolve from the kernel's startup directory.

### Web page access

Set `DEEPSEEK_API_KEY` to let `read_resource` fetch web pages as Markdown. DeepSeek receives the full page URL, including its query string. If one DeepSeek key serves both purposes, assign it to both `DEEPSEEK_API_KEY` and `LLM_API_KEY`.

Opening the original URL again starts a new Fetch request. DeepSeek charges for each successful request that returns page content. To read another passage from the same copy, use the returned snapshot URI. See [web page snapshots](resources.md#web-pages) and [DeepSeek's billing terms](https://api-docs.deepseek.com/guides/search/#billing).

Ivenna sends supported image references to the configured model service for retrieval. The image view works with web page retrieval disabled. See [remote images](resources.md#remote-images).

### Model requests

An ordinary inference request sends the selected working history, newly admitted observations, and any [receiver and listener observations](input.md#channel-receivers-and-subscription-listeners) sampled for that turn. An activity's request can include correspondence and tool results inherited from the core. See [inference turns](input.md#inference-turns) and [retained tool content](content.md#context-and-continuity).

A handover request sends the history to summarize and a dated [sample of runtime state](input.md#sampled-state).

Core and activity sessions share the configured model and output-token limit. `LLM_MAX_OUTPUT_TOKENS` covers reasoning, assistant text, and tool-call arguments.

Ordinary core requests use a lower default reasoning effort for responsive correspondence and coordination. Activities use a higher default for deeper reasoning. Handover requests in either role use `LLM_COMPACTION_REASONING_EFFORT`. To override any of the three defaults, set the corresponding variable to a nonempty effort name supported by your model. Ivenna sends that name as written. See the [configuration table](#configuration) and [DeepSeek Responses request fields](https://api-docs.deepseek.com/api/create-response/).

`LLM_REQUEST_TIMEOUT_MS` applies separately to each inference attempt, including compaction. A temporary outage can therefore delay a decision beyond this timeout. For each file upload, the timeout covers the entire negotiation. See [when model work stalls](#when-model-work-stalls) and [file outcomes](content.md#complete-files).

### Context budgets

The kernel considers summarizing older history when the last committed ordinary round's input token count reaches `CONTEXT_COMPACT_AT_TOKENS`. When that count is unavailable, as on a new activity's first request, the kernel uses `CONTEXT_COMPACT_AT_BYTES`. It measures the encoded request with the older history before adding pending work or new observations. See [what compaction measures](architecture.md#when-compaction-runs).

`CONTEXT_OBSERVATION_BATCH_BYTES` sets the target for encoded bytes added by a batch of new observations. The first observation can exceed that target if the full request fits the adapter's limits. See [how observations are admitted](architecture.md#activation-admission).

For a model with a shared input and output window, reserve `LLM_MAX_OUTPUT_TOKENS` for output. Set the token threshold below the remaining input space to leave room for a complete tool exchange and incoming observations. Evaluate compaction frequency and continuity on representative work. See [DeepSeek model metadata](https://api-docs.deepseek.com/api/list-models/), [evaluating compaction](testing.md#evaluating-compaction), and [evaluating continuity](testing.md#evaluating-continuity-across-interruptions).

The [model request limits](content.md#model-request-checks) apply to the complete encoded request. The model service checks its own limits after processing the input.

If a focus pauses at a request limit, check the logs for the limit it hit. The history and queued observations remain available when the focus resumes. See [when model work stalls](#when-model-work-stalls) and [handover outcomes](architecture.md#continuing-with-a-handover).

### Session and command capacity

`MAX_SESSIONS` counts the core and all registered activities, including those asleep. Startup fails if saved identities exceed it; with a value of `1`, only the core fits. New forks fail at capacity, while existing sessions remain addressable. Activity completion releases a slot. Ready sessions can advance concurrently. Host commands have a separate live limit and [handle retention lifecycle](host.md#command-lifetimes). The session and command defaults are tuning starting points; size them for the workload and resources available.

`MAX_PENDING_EVENTS` counts correspondence, callbacks, assignments, and focus messages buffered for a session. Subscription reports wait in SQLite until they fit an ordinary request. Startup observations, activity expressions, endings, and notices of activity interruption are exempt from the queue limit. Correspondence and callback mail have independent intake allowances and stay in their mailboxes when their destination is full. A focus message returns `focus_queue_full` when the recipient cannot accept it. Capacity and polling can delay scheduled work.

## Changing the model

Choose a DeepSeek model that supports the configured tools and reasoning efforts and can read the reasoning items and media in the history you plan to resume. For history with uploaded documents, check which models accept file IDs and keep access to the account that owns those files. See the [DeepSeek Files API](https://api-docs.deepseek.com/guides/files_api/) and [uploaded model files](#uploaded-model-files).

Stop the kernel, update `LLM_MODEL` and any changed service settings, then restart with the same instance data. A change to the model name or service endpoint makes the saved input token count unavailable to [soft compaction](#context-budgets). See [stopping and restarting](#stopping-and-restarting).

## Mail service

Use a dedicated account for Ivenna's communication records, callback inbox, and working history. Run one kernel per account. The account requires JMAP Mail and Submission capabilities, a sending identity matching `MAIL_ADDRESS`, and a Drafts folder. It must let the kernel create folders, create and move messages, and update private keywords. Ivenna creates the top-level `Ivenna Callbacks` and `Ivenna History` folders and a mailbox with role `trash` when missing. The dedicated folders have no special mail role.

Set `MAIL_ADDRESS` and authentication settings for the kernel account. Set `MAIL_SESSION_URL` to the URL of the JMAP session document. Discovery follows up to three redirects within the same scheme, host, and effective port. For a longer chain or a change of origin, configure the final session URL directly.

For correspondence, require authenticated submission and From addresses the submitting account is authorized to use. Ivenna relies on these checks to attribute each message to its correspondent. Apply them and the [reception-readiness policy](#service-status-and-reception) to every receiving path used for correspondence. The [local mail setup](../dev/README.md#configuring-mail) supplies an SMTP configuration.

Wakeup and host completion callbacks are created directly through JMAP in `Ivenna Callbacks`. The existing account and receiving policy need no additional alias, account, or SMTP exception. Keep pending callback mail in this folder with its private metadata intact: moving it elsewhere removes it from callback intake, and the runtime does not move it back. Stored callbacks remain available while the kernel is stopped. See [callback observations](attention.md#callback-observations) for the delivery contract.

Configure automatic Trash expiry and cleanup of unreferenced storage in the mail service. These processes must continue independently of the kernel. Choose retention with the provider's full policy scope in mind: Trash and Junk policies can also remove ordinary mail. The [local Stalwart setup](../dev/README.md#configuring-mail) provides a concrete configuration.

Allow for correspondence, history from all focuses, pending records, and mail awaiting expiry in Trash when setting the account quota. See [data and retention](#data-and-retention) for folder lifetimes and [mail intake](#mail-intake) for how the kernel handles existing correspondence.

### Working history limits

Set the mail service's advertised `maxSizeRequest` high enough for the JMAP request that writes your largest history record or checkpoint. Allow for the JSON envelope, any HTTP body limit at the mail endpoint or proxy, and the mail store's message limits. See [sizing the supplied Stalwart instance](../dev/README.md#sizing-stalwart-for-working-history) and [history storage](architecture.md#history-storage).

A model response and all of its tool results share one history record. Estimate space for everything that can arrive in one round. Base64 uses about four bytes for every three bytes of inline image data. Two 32 MiB images contribute about 85 MiB before the rest of the round and the JMAP envelope. The model service applies its own [inference request limits](content.md#model-request-checks).

| Error | What to check |
| --- | --- |
| `HistoryRecordTooLarge` | A single history record exceeds `maxSizeRequest` with its request envelope. For a tool round, check the combined size of its results. |
| `HistoryCheckpointTooLarge` | The checkpoint request exceeds `maxSizeRequest`. Check the number of registered focuses, open channels, and pending wakeups. |
| HTTP 413 on `Email/set` | Check HTTP body limits at the proxy and mail endpoint. |
| `MailObjectFailed` on `Email/set` | Check the mail server's rejection details, including message limits and account quota. |

`HistoryRecordTooLarge` and `HistoryCheckpointTooLarge` stop the kernel before it sends the oversized request. Restart resumes from the previously published checkpoint. If the failed save included a tool round, that checkpoint has no saved results for the round. Check for effects such as a file upload or a host command before restarting, since the focus may act again when it resumes.

Raise the applicable mail service or proxy limit and restart with the same mailbox and instance database. If channel registrations contributed to the checkpoint size, close unused channels once reception opens.

### Outgoing correspondents

Set `MAIL_CORRESPONDENTS` to a comma-separated list of full mailbox addresses in the domain of `MAIL_ADDRESS`, such as `operator@ivenna.test,reviewer@ivenna.test`. Include `MAIL_ADDRESS` to allow Ivenna to write to itself. An unset or empty list registers no recipients. Inbound correspondence follows the [mail intake rules](#mail-intake).

Spaces and tabs around entries are ignored. Repeated addresses for the same mailbox register one correspondent. `InvalidCorrespondentAddress` indicates an empty entry, an unsupported mailbox address, or a different domain. Restart the kernel to apply changes. See [correspondent IDs](communication.md#current-email-addressing).

### Mail intake

The kernel reads correspondence awaiting durable admission across the account's mail folders, including the mail client's ordinary Archive folder. `Ivenna Callbacks`, `Ivenna History`, Drafts, Junk, and Trash are excluded from ordinary correspondence, along with drafts and records carrying private callback, outgoing, or history-state markers. The callback inbox has its own admission path; these records do not become correspondence.

The adapter selects messages with supported sender addresses and a complete supported body. If it cannot read the body, it logs a diagnostic and leaves the mail copy intact. See [email addressing](communication.md#current-email-addressing) and [incoming email text](communication.md#incoming-email-text).

Eligible correspondence without the private acknowledgement marker is pending, including existing messages that have been read or archived. Once its complete observation and checkpoint have been saved, Ivenna acknowledges the message and moves its incoming copy to Trash before reasoning about that input. Reading, starring, or moving correspondence does not acknowledge it. The [communication-copy lifecycle](#communication-copies) also applies to existing mail in this dedicated account.

## Memory service

### SSH connection

Set `MEMORY_SSH_TARGET` to the memory service's SSH target. Set `MEMORY_SSH_CONFIG` to a dedicated file, or leave it unset to use standard OpenSSH configuration. The connection must work without interactive input.

The adapter sets a 10-second connection timeout, sends keepalive checks every 15 seconds, and permits two unanswered checks. After preparing the request payload, it applies a fixed 60-second deadline to request writing, response reading, and SSH completion. A timeout stops and joins the local SSH process and ends the runtime; it does not establish whether a remote write took effect. Requests are not automatically retried.

### Handler and entry point

The current memory adapter invokes `/usr/local/bin/memory-shell` over SSH and exchanges JSON requests and replies with [memory.nu](../apps/memory/src/memory.nu). The service needs Nushell, ripgrep, fd, and `flock`. Use the Nushell version selected by the [Containerfile](../apps/memory/Containerfile), and install the programs on the `PATH` used by the memory shell.

Install the handler and prepare the SSH entry point using [memory-shell.sh](../apps/memory/memory-shell.sh) and [sshd_config](../apps/memory/sshd_config) as references. Choose the handler location for the service and set it in the shell wrapper. The supplied wrapper uses `/usr/local/lib/ivenna/memory.nu`.

### Workspace and locking

The shell wrapper selects the memory workspace through its working directory and holds a lock for each handler invocation. Choose the workspace and lock paths for the service. The supplied wrapper uses `/memory` for the workspace and `/run/ivenna/memory.lock` for the lock.

The SSH account needs read and write access to the workspace and lock. Create the lock's parent directory and lock file at service startup with the permissions needed by that account; [entrypoint.sh](../apps/memory/entrypoint.sh) provides an example. All handler processes sharing the workspace must use the same lock.

The selected Nushell backend treats names consisting only of three or more dots as parent-directory syntax. Choose a workspace path without such components. If an external program creates a directory with a name such as `...` inside the workspace, rename it before using the service; capacity accounting cannot safely traverse it.

The handler owns `.ivenna-tmp` at the workspace entrance for unpublished writes. It verifies its ownership marker before cleaning this directory; an existing unowned entry at that address is a service-setup conflict and remains untouched. Keep deployment-managed files and memory entries at other addresses.

### Capacity

Set `MEMORY_CAPACITY_BYTES` in the memory service's environment, through its shell wrapper or the SSH server's `SetEnv`. It is a positive byte count and defaults to `1073741824` (1 GiB). See [memory space](memory.md#memory-space) for capacity behavior. Apply changes to the environment used by new handler invocations.

The [local development setup](../dev/README.md#configuring-memory) packages this service in a container and prepares its SSH connection.

## Starting the kernel

`ivenna --help` displays usage before you configure the services. To start the kernel, prepare the services and export the required [environment settings](#configuration). Run `ivenna serve` from the directory where you want file browsing and host commands to start by default.

```sh
cd /path/to/workspace
export DATA_DIR=/path/to/instance/data
/path/to/ivenna serve
```

The executable embeds its model-facing resources and can run independently of the source checkout.

Give each kernel its own mailbox, `DATA_DIR`, and `SERVICE_ADDRESS`. If startup reports `AddressInUse`, check whether another process owns `SERVICE_ADDRESS` or a kernel is already running for the data directory.

The kernel opens the instance database, initializes mail, checks memory, restores saved sessions or creates the core, and completes storage maintenance before opening reception. Check [reception readiness](#service-status-and-reception) before [sending a letter](usage.md#sending-a-letter). The kernel writes diagnostics to standard error.

Startup reads and validates all selected session history, including sleeping sessions. Allow for the resulting I/O and temporary memory use when sizing the deployment. See [history restoration](architecture.md#saving-and-restoration) for context loading behavior.

## Channel receivers

Use the same build of `ivenna` for the kernel and the receiver. Run both in the same Linux network namespace under the same effective UID. Both processes must resolve `DATA_DIR` to the same absolute path after following symbolic links. When using separate containers, share the kernel's network namespace and mount the instance data directory at the same path. If the containers remap users, the effective UID must have the same number and map to the same Linux user on both sides.

For a receiver launched independently, set `DATA_DIR` to the instance data directory and pass the complete ID returned by `open_channel`.

```sh
DATA_DIR=/path/to/instance/data /path/to/ivenna channel receive 'task-input-18'
```

Ivenna's own host commands inherit the resolved `DATA_DIR` and the executable path in `IVENNA`. See the [host command environment](host.md#command-environment) and [receiver session](communication.md#receiving-from-a-channel).

If `channel receive` reports that the channel service is unavailable, check that the kernel is running and review the requirements above. The kernel can also refuse a connection when all receiver slots are in use.

## Subscription listeners

Run subscription listeners on the kernel host. Set `DATA_DIR` to the instance's data directory. Use an absolute path for an independently launched listener that may start from a different working directory. Ivenna's host commands inherit absolute paths in `IVENNA` and `DATA_DIR`. [Host command environment](host.md#command-environment) · [Listener protocol](subscriptions.md#keep-a-listener-session-open)

The listener needs write access to the database, its SQLite sidecar files, and their directory. The kernel and listeners also need read access to the same `<DATA_DIR>/subscription-listeners.lock` on a filesystem that supports Linux open-file-description locks. The first process creates it with owner-only permissions. If the kernel and listener run as different users, give both users read access to the file.

Keep the existing lock file in place while the kernel or a listener is running. Replacing it leaves existing processes holding the old file while new processes open the replacement. See [listener connections](architecture.md#listener-connections).

Run the listener independently when it needs to keep collecting through a kernel stop or restart. Its session can stay open and save reports to the instance database while the kernel is stopped. Those reports wait there for delivery after restart. Listeners launched as Ivenna host commands stop with the kernel. See [host command lifetimes](host.md#command-lifetimes).

## Service status and reception

The HTTP listener at `SERVICE_ADDRESS` reports listener health and mail reception separately.

| Endpoint | Response |
| --- | --- |
| `GET /healthz` | `200 OK` for listener health |
| `GET /readyz` | `200 OK` with `X-Ivenna-Ready: true` when reception is open, `503 Service Unavailable` when closed |

Reception stays open during startup reasoning and while a focus waits for the model. Check its state at the configured address. For the default port on the kernel host, run this command.

```sh
curl --include http://127.0.0.1:8090/readyz
```

Configure the mail receiving boundary to check the readiness header at an address it can reach and reject incoming traffic when the header is absent, including when the endpoint cannot be reached. Apply the policy to every receiving address and delivery path used for correspondence. The [local Stalwart setup](../dev/README.md#configuring-mail) demonstrates an SMTP recipient check.

An accepted letter can wait in the mailbox if a focus is busy or the kernel stops after delivery. On restart the kernel reads [pending correspondence](#mail-intake) already in its account.

### When a mail request fails

Look for `JMAP` on the kernel's standard error. A failed request logs its method, stage, and error. A warning ending in `Retrying on a fresh connection` means another attempt is underway. Check `/readyz` for the current reception state. See [JMAP requests](architecture.md#jmap-requests) for which operations can retry.

Reception can stay open even if Ivenna loses confirmation while sending a reply. Check the reply's `send` result in [working history](#working-history) to see whether Ivenna confirmed submission. Trash can contain both submitted messages and abandoned drafts. See [correspondence outcomes](communication.md#writing-to-a-correspondent).

If the kernel cannot read or confirm required mailbox state, it closes reception and exits. Even a duplicate delivery requires a confirmed acknowledgement. For a `connect` failure, check whether the kernel can reach the mail endpoint. For HTTP 401, check the credentials configured for the [mail account](#mail-service). For a history size error, see [working history limits](#working-history-limits).

### When model work stalls

To follow a focus, look for its ID in the kernel's standard error. `retrying inference` gives the wait before its next attempt. `inference resumed` means a retry returned a model response. An `interrupted` message gives the reason the focus paused. A retry alone leaves the [checkpoint revision](#working-history) unchanged. Other focuses can advance it while this one waits.

For inference HTTP errors, the adapter logs the status and the service's request ID when available. It also logs a usable error code from an HTTP 400 or 429 response. Include the request ID when contacting the model provider about a rejection.

- **Temporary outage.** The kernel retries ordinary inference and summaries needed to resolve a hard limit. During soft compaction, a temporary failure returns control to the ordinary request. The first retry wait is 250–500 milliseconds. The range doubles after each failure up to 2.5–5 minutes. A longer delay requested by the service in `Retry-After` takes precedence. Retries reuse completed tool results. A lost model response can still incur charges.
- **Interrupted focus.** A rejected request or an unusable response pauses the focus with its history intact. This includes letters saved and acknowledged before inference, even if the model service rejects the request for exceeding its token window. Another observation can resume the focus, and the core receives a notice if an activity was interrupted. If HTTP 403 or 404 recurs across focuses, check model access and `LLM_BASE_URL`.
- **Kernel exit.** A shared failure on the inference endpoint, such as HTTP 401, exhausted account quota, or an incompatible protocol, closes reception and stops the kernel. Correct the reported problem before restarting. See [model transport](architecture.md#model-transport).

For a file upload rejection, look for `model file endpoint returned HTTP` in the kernel log. Ivenna records the rejection in the tool result and can continue with the next inference, including when the file endpoint returns HTTP 401. See [file upload outcomes](content.md#complete-files).

### Recovering from an admission failure

If the core cannot admit an incoming letter within the adapter's request limits, the letter stays unacknowledged in the mailbox. Later correspondence waits behind it. Another accepted observation or a restart can prompt a new attempt. Polling that same letter leaves it pending.

If admission keeps failing, look for a request-limit warning under the focus's ID in the kernel log. It gives the measured size or count and the applicable limit. To withdraw an oversized letter, stop the kernel, move it out of eligible intake, then restart. The kernel rebuilds pending deliveries from the mailbox. You can send a shorter letter with a reference to the original material. See [model request limits](content.md#model-request-checks), [mail intake](#mail-intake), and [sharing material to read](usage.md#sharing-material-to-read).

A subscription report that cannot fit stays in the instance database. Withdrawing the subscription closes it to new reports. The focus still needs enough request space to receive the one already accepted.

## Stopping and restarting

Send `SIGTERM`, or press `Ctrl+C` when running in a terminal, to close reception, cancel session work (including model recovery waits) and host commands, and wait for the runtime's tasks to end. Failure of a required service such as history storage, or an unrecoverable execution error, also stops the runtime. Diagnose the failure and restore any unavailable services before restarting.

Run `ivenna serve` with the same mail account, `MAIL_ADDRESS`, and `DATA_DIR` to resume saved focuses and pending deliveries. Keep access to the configured memory workspace and to host artifacts still needed for the work. If startup reports `SubscriptionCatalogMismatch`, check that the mailbox and instance database belong to the same instance. When restoring data, use [matched backups](#backups-and-transfers).

A checkpoint whose publication was unconfirmed can still be selected on restart. Startup confirms a fresh checkpoint for the restored state before reception opens. See [startup recovery](architecture.md#startup-and-interruption).

At restart the core sees the current outgoing correspondent IDs, including changes to [`MAIL_CORRESPONDENTS`](#outgoing-correspondents). An activity with unfinished work can also resume on startup. See the [startup observation contract](input.md#startup-and-restart) for delivery timing. A letter can appear again if the kernel stopped between saving the observation and acknowledging its mail copy.

Registered wakeups and host completions keep their original receiving sessions across restart. Wakeups whose scheduled times passed while the kernel was unavailable become due. For a host completion, Ivenna uses the stored result when available and reports an interruption with unknown effects otherwise.

Stopping the kernel cleans up its host commands and disconnects channel receivers. After restart, receivers can reconnect to restored channel IDs, including channels whose opening activity ended. Independently run subscription listeners can keep their sessions open. See [channel lifetimes](communication.md#channel-lifetimes) and [subscription listener deployment](#subscription-listeners).

An interrupted operation may have produced effects without a saved result. Include known external changes when corresponding about interrupted work. See [after interruption](usage.md#after-interruption) and the [recovery state inventory](architecture.md#recovery-state).

### Updating the executable

Before updating across a change in storage format, make a [matched backup](#backups-and-transfers) and keep the executable that can read it. Use that executable to resume the instance from the backup if needed. To start a fresh instance, use a separate mailbox and `DATA_DIR`.

If `ivenna serve` reports `IncompatibleStateSchema`, check `DATA_DIR` and use a build that supports the instance database's schema. After installing an update, start its kernel before connecting new listeners so startup can apply any supported migration.

See [upgrading Ivenna](upgrading.md) for changes that require deployment steps.

## Data and retention

The deployment chooses storage for the mail account, memory workspace, and kernel data directory independently. Uploaded files live in the DeepSeek account.

| Location | Contents |
| --- | --- |
| Configured JMAP account | Pending and retired correspondence and callback mail, working-history records and checkpoints, and private markers |
| Configured memory workspace | Shared memory rooms and entries |
| `<DATA_DIR>/host/` | Full stdout and stderr from host commands |
| `<DATA_DIR>/state.sqlite3` | Subscription registrations, accepted keys, and queued reports. See the [instance database](architecture.md#instance-database). |
| `<DATA_DIR>/subscription-listeners.lock` | File used to coordinate [open listener sessions](architecture.md#listener-connections). |
| DeepSeek account | [Uploaded files](#uploaded-model-files) and their parsing results |

Web page snapshots expire on eviction or kernel restart. Previously read passages remain in retained tool results. To reach a new passage after expiry, fetch the original URL again, which may now return a different version. See [web page snapshots](resources.md#web-pages).

Ivenna moves correspondence and callback copies no longer needed for admission or submission, and history no longer selected for continuation, to Trash. Trash provides the mail service's retention window before deletion. Moving an object to Trash leaves its contents on the service until that policy takes effect; service maintenance controls expiry and physical storage reclamation independently of the kernel.

Ivenna does not monitor quota or evict live records in response to account capacity. A failure in Ivenna's storage maintenance stops the runtime like other storage failures.

### Communication copies

| Copy in Ivenna's account | When Ivenna moves it to Trash |
| --- | --- |
| Incoming message | After saving its complete observation and checkpoint, before reasoning about the request |
| Internal callback | After saving the registered observation in the receiving session's history |
| Outgoing message | At startup or before a mail poll, once the draft is no longer in use for sending. This includes drafts left by interrupted sends. |

An identifiable callback copy, including one in Trash, preserves the first result for that callback ID. Once the copy expires, a publisher can create another. If the receiving session has already admitted that ID, the kernel acknowledges the new copy without presenting the observation again. See [callback admission](architecture.md#event-sources-and-callback-admission).

Keep original correspondence separately if you need it beyond the Trash retention period. Compaction can replace detailed observations and tool exchanges with a handover. Correspondents manage their own copies.

### Working history

The kernel publishes checkpoints in `Ivenna History` as messages with the subject `Ivenna history checkpoint`. The selected checkpoint identifies separate records for each session's working history, its pending internal observations (including queued assignments), and the activity outbox's unread reports. Pending observations and reports enter the receiving focus's working history on admission. See the [storage layout](architecture.md#persistent-working-history) and [recovery state inventory](architecture.md#recovery-state).

An idle kernel typically publishes two revisions when the core receives a letter and the model responds without tool calls. The first saves the incoming observation before Ivenna acknowledges the letter. The second saves the model response.

Ivenna cleans up the history folder at startup and periodically while it runs. Unpublished preparations and superseded checkpoints can remain in `Ivenna History` between passes. To identify the checkpoint selected on restart or diagnose `AmbiguousHistoryRevision`, see [mailbox checkpoint selection](architecture.md#history-storage).

| Location | Objects kept or moved during maintenance |
| --- | --- |
| `Ivenna History` | Selected published checkpoint and the records it selects for session histories, pending internal observations, and unread activity reports |
| Trash | Unselected checkpoints and history records |

Forks store independent copies of inherited history. Include these copies when sizing runtime memory and the mailbox. Compaction replaces older records with a handover and carries forward selected recent records. Previous records can then move to Trash while other sessions keep their own copies.

A sleeping activity retains its history even when its context is unloaded. When the activity ends, the next confirmed checkpoint omits its working history, allowing maintenance to move those records to Trash. The activity's messages and ending remain available to the core until they enter the core's history. Shared memory follows its own lifecycle. See [history retention](architecture.md#history-retention) for selection rules.

Unread activity expressions retain each text in order with its original observation time. Ending times are also retained. The core admits reports that fit its ordinary request. Unread reference metadata grows with the backlog, and all unread bodies occupy mailbox storage. Activity messages and endings are outside `MAX_PENDING_EVENTS`, so size runtime memory and mailbox capacity for work that can accumulate before the core next reads it. See [activity reports](architecture.md#activity-reports) for reading and admission behavior.

### Subscription retention

Pending subscription reports can accumulate on disk while the kernel is stopped or a focus cannot admit them. The kernel removes each report from the queue once it confirms the observation in the focus's history. Each distinct accepted key stays in the database until withdrawal, even after the queue drains. See [listener retries](subscriptions.md#write-receipts-and-recovery).

### Uploaded model files

Uploads belong to the DeepSeek account authenticated by `LLM_API_KEY`. Ivenna leaves expiration unset, so DeepSeek keeps the files until deletion, even after Ivenna retires the history that referred to them. Deleting an upload invalidates its ID in every focus or mailbox backup that refers to it. See the [DeepSeek Files API](https://api-docs.deepseek.com/guides/files_api/#upload-a-file).

DeepSeek can finish parsing and store a file after the connection closes. Use the account's file list to inspect uploads after an unconfirmed result. Keep the original host file or memory entry for access to the original bytes. See [listing uploads](https://api-docs.deepseek.com/guides/files_api/#list-files) and [file upload outcomes and charges](content.md#complete-files).

### Backups and transfers

Back up the mailbox and instance database as a pair. Startup checks the database identity, which stays the same across snapshots of an instance. Pairing an older mailbox with a newer database can lose a report if the database removed it after the mailbox snapshot was taken.

If taking the mailbox and database backups separately, stop the kernel before either backup begins and leave it stopped until both finish. Use a [SQLite backup](https://www.sqlite.org/backup.html) of `<DATA_DIR>/state.sqlite3`. For a direct file copy, stop independent listeners too and include any SQLite sidecar files with the database.

Save listener progress before taking the database backup so the saved positions are covered by that backup. Include buffered reports the source cannot replay. [Source progress](subscriptions.md#resume-at-the-source)

To restore an instance, stop the kernel, subscription listeners, and any channel receivers that reconnect automatically. Move the current database and any accompanying SQLite journal, write-ahead log, or shared-memory files aside. Restore the database and mailbox from the matched backup.

Resume listeners using their restored subscription IDs. Restore their source progress from the corresponding backup or replay from an earlier position using the original report keys. Reuse restored channel IDs when they still identify the intended channels. If the backup predates a channel registration, open a replacement channel and give its ID to the receiver. See [channel lifetimes](communication.md#channel-lifetimes).

History and callback mail are JMAP Email objects. A backup or transfer used for continuation must preserve the selected checkpoint, every session and outbox record it selects from `Ivenna History`, and pending mail in `Ivenna Callbacks`.

| Applies to | Preserve |
| --- | --- |
| History bodies | Exact plain-text ZON content |
| All selected history objects | Original membership in `Ivenna History`, From and To addresses matching `MAIL_ADDRESS`, `ivenna-state`, and `X-Ivenna-History-Kind` (`record` or `checkpoint`) |
| Records | `ivenna-history-<token>`, `X-Ivenna-History-Key`, and `X-Ivenna-History-Previous` when present |
| Selected checkpoint | `ivenna-current`, `ivenna-prepared` when present, and `X-Ivenna-History-Revision` |
| Pending callback mail | Complete text, From and To matching `MAIL_ADDRESS`, membership in `Ivenna Callbacks`, `ivenna-callback`, exact `ivenna-callback-<id>` keyword, and matching `X-Ivenna-Callback-Id` header |

The callback keyword and header contain the internal numeric delivery ID; the checkpoint registration preserves its complete named reference.

Native `Email.id` values may change because restoration uses checkpoint markers and revisions, logical groups and record keys, and callback IDs. See [mailbox checkpoint selection](architecture.md#history-storage) to identify the selected checkpoint and [updating the executable](#updating-the-executable) for storage-format compatibility.

Earlier checkpoints are retired through Trash and do not provide rollback. Preserve a complete backup separately if it is needed after the mail service's retention period.

A mailbox backup carries saved channel registrations, stored callbacks, and wakeup arrangements. Keep access to any [uploaded files](#uploaded-model-files) referenced by the backup. Preserve host artifacts and memory data separately when continued work needs them. See [host output and deployment files](#host-output-and-deployment-files) and [stopping and restarting](#stopping-and-restarting) for what survives a restart.

### Host output and deployment files

Set `DATA_DIR` to writable storage that supports ordinary files and subdirectories. An absolute path keeps output storage stable across changes to the kernel's startup directory. Launching a command creates any missing output directories with private permissions.

Host output files remain available after the command and activity session end. Retained material can refer to their paths, so preserve files still needed for continued work. Automatic output cleanup is not implemented.

Keep provisioning files, credentials, and SSH keys with the deployment configuration. The [local development data reference](../dev/README.md#development-data) lists the Compose volumes and files used by the supplied setup.
