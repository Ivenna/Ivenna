# Running Ivenna

The Ivenna kernel connects to a model service, a mail service, and an SSH workspace for autonomous memory. This guide covers runtime requirements, configuration, startup, and data retention. For the supplied local environment, follow the [local development guide](../dev/README.md).

## Runtime requirements

Install `ivenna` and `ivenna-report` from the same build in the same directory so the kernel can locate the reporter for host commands. The kernel's execution environment needs `/bin/sh` and an OpenSSH client. See the [build instructions](development.md#repository-and-build).

The core and activities can read regular files and list directories wherever the kernel's OS account has access. Choose the account and filesystem mounts accordingly. Host commands run as the same account.

Terminal mode additionally requires Linux 5.3 or newer with `pidfd_open`, `pidfd_send_signal`, and `TIOCGPTPEER` available, a working `/dev/ptmx` backed by devpts, and util-linux `setsid` at `/usr/bin/setsid`. It enumerates processes under `/proc` to find and clean up its session's foreground and background jobs. Batch and pipe modes do not require this terminal transport.

The application uses the Responses adapter with DeepSeek as the default model service. Supply its API key, or configure a Responses-compatible endpoint and model through `LLM_BASE_URL` and `LLM_MODEL`. [File input](content.md#complete-files) additionally requires DeepSeek-compatible Files API parsing and `input_file` references; the default `deepseek-flash` supports them. The kernel also needs access to the [mail service](#mail-service) and [memory service](#memory-service). The mail receiving boundary needs access to the kernel's [reception status](#service-status-and-reception).

## Configuration

The kernel reads its process environment at startup. Supply settings through the deployment's launcher or service manager. To use an environment file, export its values before launching, as shown in the [local configuration steps](../dev/README.md#configuration). Apply changes by restarting the kernel with the updated environment.

Set connection addresses, identities, and storage paths for the chosen deployment. The table lists required settings and the current executable's defaults.

| Variable | Purpose | Default when unset |
| --- | --- | --- |
| `LLM_API_KEY` | Model API key | Required |
| `LLM_BASE_URL` | Model API base URL | `https://api.deepseek.com` |
| `LLM_MODEL` | Model name | `deepseek-flash` |
| `LLM_MAX_OUTPUT_TOKENS` | Maximum output tokens per response, including reasoning tokens | `65536` |
| `LLM_REQUEST_TIMEOUT_MS` | Time limit for one inference attempt or one file upload, including upload negotiation | `600000` (10 minutes) |
| `LLM_CORE_REASONING_EFFORT` | Reasoning effort for ordinary core requests | `low` |
| `LLM_ACTIVITY_REASONING_EFFORT` | Reasoning effort for ordinary activity-session requests | `high` |
| `DEEPSEEK_API_KEY` | DeepSeek Fetch credential for [web page access](#web-page-access) | Web page retrieval disabled |
| `CONTEXT_COMPACT_AT_TOKENS` | Input-token threshold for compaction | `262144` |
| `CONTEXT_COMPACT_AT_BYTES` | Fallback threshold for compaction, in encoded request bytes | `1048576` (1 MiB) |
| `CONTEXT_OBSERVATION_BATCH_BYTES` | Target for the encoded bytes a batch of observations adds to a request | `1048576` (1 MiB) |
| `SERVICE_ADDRESS` | HTTP health and reception-readiness listener | `0.0.0.0:8090` |
| `MAIL_SESSION_URL` | URL for [JMAP session discovery](#mail-service) | `http://127.0.0.1:8088/jmap/session` |
| `MAIL_ADDRESS` | Kernel mailbox address and sending identity | Required |
| `MAIL_CORRESPONDENTS` | Full mailbox addresses registered for the `send` tool, separated by commas | No registered recipients |
| `MAIL_USERNAME` | Mail login | Required for username/password authentication |
| `MAIL_PASSWORD` | Mail password | Required for username/password authentication |
| `MAIL_AUTHORIZATION` | Complete HTTP Authorization header | Unset; use username/password |
| `MAIL_POLL_INTERVAL_MS` | Delay between intake passes for mail and subscription reports | `2000` |
| `MAX_SESSIONS` | Maximum registered session identities, including sleeping sessions and the core | `128` |
| `MAX_PENDING_EVENTS` | Maximum ordinary accepted events buffered per session | `64` |
| `MAX_HOST_COMMANDS` | Maximum live host commands across all activity sessions | `8` |
| `MAX_OPEN_CHANNELS` | Instance-wide capacity for opening feeds | `128` |
| `DATA_DIR` | Persistent directory for subscriptions, feeds, and host command output | Required |
| `MEMORY_SSH_TARGET` | Memory SSH target | `ivenna-memory` |
| `MEMORY_SSH_CONFIG` | Dedicated SSH configuration file | Standard OpenSSH configuration |

`MAIL_AUTHORIZATION` takes precedence over username/password authentication. `SERVICE_ADDRESS` must contain a literal IP address and a nonzero port; keep the [mail readiness policy](#service-status-and-reception) aligned when changing it.

Numeric kernel settings must be positive. Relative `DATA_DIR` and `MEMORY_SSH_CONFIG` paths resolve from the kernel's startup directory.

### Web page access

Set `DEEPSEEK_API_KEY` to let `read_resource` fetch web pages as Markdown. DeepSeek receives the full page URL, including its query string, whichever service handles inference. If one DeepSeek key serves both purposes, assign it to both `DEEPSEEK_API_KEY` and `LLM_API_KEY`.

Opening the original URL again starts a new Fetch request. DeepSeek charges for each successful request that returns page content. To read another passage from the same copy, use the returned snapshot URI. See [web page snapshots](resources.md#web-pages) and [DeepSeek's billing terms](https://api-docs.deepseek.com/guides/search/#billing).

Ivenna sends supported image references to the configured model service for retrieval. The image view works with web page retrieval disabled. See [remote images](resources.md#remote-images).

### Model requests

Core and activity sessions share the configured model and output-token limit. `LLM_MAX_OUTPUT_TOKENS` covers reasoning, assistant text, and tool-call arguments.

Choose an ordinary reasoning effort for each role from the values supported by your model service. Ivenna accepts `none`, `minimal`, `low`, `medium`, `high`, `xhigh`, and `max`. Compaction always uses `high` with no tools.

`LLM_REQUEST_TIMEOUT_MS` applies separately to each inference attempt, including compaction. A temporary outage can therefore delay a decision beyond this timeout. For each file upload, the timeout covers the entire negotiation. See [when model work stalls](#when-model-work-stalls) and [file outcomes](content.md#complete-files).

### Context budgets

Each focus compares the input-token count from its last successful ordinary request, including cached input, with `CONTEXT_COMPACT_AT_TOKENS`. When no count is available, `CONTEXT_COMPACT_AT_BYTES` applies to the encoded request containing the older history eligible for compaction. See [what compaction measures](architecture.md#when-compaction-runs).

`CONTEXT_OBSERVATION_BATCH_BYTES` sets the target for encoded bytes added by a batch of new observations. The first observation can exceed that target if the full request fits the adapter's limits. See [how observations are admitted](architecture.md#activation-admission).

For a model with a shared input and output window, reserve `LLM_MAX_OUTPUT_TOKENS` for output. Set the compaction threshold below the remaining input space, leaving room for a complete tool exchange and incoming observations. Evaluate continuity and compaction frequency on representative work. See [DeepSeek model metadata](https://api-docs.deepseek.com/api/list-models/) and [evaluating compaction](testing.md#evaluating-compaction).

The [model request limits](content.md#model-request-checks) apply to the complete encoded request. The model service checks its own limits after processing the input.

Each open feed adds its address and description to the request. Size `MAX_OPEN_CHANNELS` for the model's context window. Existing feeds remain visible and writable after you lower the limit, and the open count must fall below it before you can create another. If the catalog alone exceeds the model's window, use a compatible model with enough context to close feeds before switching back. See [changing the model](#changing-the-model).

When compaction is optional and a usable handover cannot be prepared, the original request can proceed while it fits. If the kernel cannot assemble a request within the adapter's limits, the focus waits with its history and any unadmitted observations intact. See [handover outcomes](architecture.md#continuing-with-a-handover).

### Session and command capacity

`MAX_SESSIONS` counts the core and all registered activities, including those asleep. Startup fails if saved identities exceed it; with a value of `1`, only the core fits. New forks fail at capacity, while existing sessions remain addressable. Activity completion releases a slot. Ready sessions can advance concurrently. Host commands have a separate live limit and [handle retention lifecycle](host.md#command-lifetimes). The session and command defaults are tuning starting points; size them for the workload and resources available.

`MAX_PENDING_EVENTS` counts correspondence, callbacks, assignments, and focus messages buffered for a session. Subscription reports wait in SQLite until they fit an ordinary request. Startup observations, activity expressions, endings, and notices of activity interruption are exempt from the queue limit. Correspondence and callback mail have independent intake allowances and stay in their mailboxes when their destination is full. A focus message returns `focus_queue_full` when the recipient cannot accept it. Capacity and polling can delay scheduled work.

## Changing the model

Retained history can include native model output and reasoning data supplied by the model adapter, plus file identifiers supplied by the model service. A replacement service and model must accept those items as well as the configured tools and reasoning settings. File identifiers also require access to the account that owns the uploads. The runtime does not translate retained model output, transfer uploaded files between services, or verify in advance that a replacement model can consume them. Establish compatibility before resuming retained work with the replacement model.

Stop the kernel, update `LLM_MODEL` and any changed service settings, then restart with the same instance data. See [stopping and restarting](#stopping-and-restarting).

## Mail service

Use a dedicated account as programmatic storage for Ivenna's communication records, callback inbox, and working history, with JMAP Mail and Submission capabilities and a sending identity matching `MAIL_ADDRESS`. The account needs a Drafts folder and permission to create and move messages and update private keywords. Ivenna creates the top-level `Ivenna Callbacks` and `Ivenna History` folders and a mailbox with role `trash` when missing; the dedicated folders have no special mail role. The account must permit folder creation.

Set `MAIL_SESSION_URL` to the URL of the JMAP session document. Discovery follows up to three redirects within the same scheme, host, and effective port. For a longer chain or a change of origin, configure the final session URL directly.

Set `MAIL_ADDRESS` and authentication settings for the kernel account. Use `MAIL_CORRESPONDENTS` to register full mailbox addresses in the same domain, such as `operator@ivenna.test,reviewer@ivenna.test`. You can also register the kernel mailbox. Leaving the variable unset or empty registers zero recipients.

The application trims spaces and tabs around each entry in a nonempty list. Startup reports `InvalidCorrespondentAddress` for an empty entry or an unsupported or cross-domain address. It reports `DuplicateCorrespondentId` if entries share the same case-sensitive local part. Restart the kernel to apply changes to the list. See [correspondent addressing](communication.md#current-email-addressing).

For correspondence, require authenticated submission and From addresses the submitting account is authorized to use. Ivenna relies on these checks when presenting correspondent IDs. Apply them and the [reception-readiness policy](#service-status-and-reception) to every receiving path used for correspondence. The [local mail setup](../dev/README.md#configuring-mail) supplies an SMTP configuration.

Wakeup and host completion callbacks are created directly through JMAP in `Ivenna Callbacks`. The existing account and receiving policy need no additional alias, account, or SMTP exception. Keep pending callback mail in this folder with its private metadata intact: moving it elsewhere removes it from callback intake, and the runtime does not move it back. Stored callbacks remain available while the kernel is stopped. See [callback observations](attention.md#callback-observations) for the delivery contract.

Configure automatic Trash expiry and cleanup of unreferenced storage in the mail service. These processes must continue independently of the kernel. Choose retention with the provider's full policy scope in mind: Trash and Junk policies can also remove ordinary mail. The [local Stalwart setup](../dev/README.md#configuring-mail) provides a concrete configuration.

The [intake rules](#mail-intake) also apply to existing correspondence in the account. Working history shares the account's storage capacity; [data and retention](#data-and-retention) explains its folder lifecycle and backup requirements.

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

`ivenna --help` displays usage before you configure the services. To start the kernel, prepare the services and export the required [environment settings](#configuration). Run `ivenna` from the directory where you want file browsing and host commands to start by default.

```sh
cd /path/to/workspace
export DATA_DIR=/path/to/instance/data
/path/to/ivenna
```

The executable embeds its model-facing resources and can run independently of the source checkout.

Give each kernel its own mailbox and `DATA_DIR`. The kernel binds `SERVICE_ADDRESS` before accessing the account. If the address is in use, startup exits. On Linux, an `AddressInUse` error just after an upgrade can persist until the older executable's connections leave `TIME_WAIT`.

The kernel initializes mail, checks memory, restores saved sessions or creates the core, and completes storage maintenance before opening reception. Check [reception readiness](#service-status-and-reception) before [sending a message](usage.md#sending-a-request). The kernel writes diagnostics to standard error.

Startup reads and validates all selected session history, including sleeping sessions. Allow for the resulting I/O and temporary memory use when sizing the deployment. See [history restoration](architecture.md#saving-and-restoration) for context loading behavior.

## Subscription listeners

Start the program that watches the source and give it the `subscription_id` returned when a focus [registers the subscription](attention.md#subscriptions). When the subscription is withdrawn, stop the listener if it has no other work.

A listener running as a host command inherits the reporter's absolute path in `IVENNA_REPORT` and the kernel's data directory in `DATA_DIR`. It stops with the kernel. Its [completion callback](host.md#command-lifetimes) keeps the launching activity available while the command runs.

To keep collecting while the kernel is stopped, run the listener independently, for example under a service manager on the same host. Give it the path to the installed `ivenna-report` and point its `DATA_DIR` at the directory the kernel initialized. An absolute path works even when the two programs start in different directories. The reporter needs read and write access to the existing subscription database and its directory. Limit that access to trusted processes. Reports accepted during downtime are available to their subscribing focus after restart. See the [listener protocol](subscriptions.md) for publication and cursor recovery.

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

Reception can stay open even if Ivenna loses confirmation while sending a reply. To see what Ivenna learned about submission, look for the reply's `send` result in [working history](#working-history). Trash can contain both submitted messages and abandoned drafts. See [sending outcomes](communication.md#sending-a-message).

If the kernel cannot read or confirm required mailbox state, it closes reception and exits. For a `connect` failure, check whether the kernel can reach the mail endpoint. For HTTP 401, check the credentials configured for the [mail account](#mail-service).

### When model work stalls

To follow a focus, look for its ID in the kernel's standard error. `retrying inference` gives the wait before its next attempt. `inference resumed` means a retry returned a model response. An `interrupted` message gives the reason the focus paused. A retry alone leaves the [checkpoint revision](#working-history) unchanged. Other focuses can advance it while this one waits.

For inference HTTP errors, the adapter logs the status and the service's request ID when available. It also logs a usable error code from an HTTP 400 or 429 response. Include the request ID when contacting the model provider about a rejection.

- **Temporary outage.** The kernel retries ordinary inference and summaries needed to resolve a hard limit. During soft compaction, a temporary failure returns control to the ordinary request. The first retry wait is 250–500 milliseconds. The range doubles after each failure up to 2.5–5 minutes. A longer delay requested by the service in `Retry-After` takes precedence. Retries reuse completed tool results. A lost model response can still incur charges.
- **Interrupted focus.** A rejected request or an unusable response pauses the focus with its history intact. This includes letters saved and acknowledged before inference, even if the model service rejects the request for exceeding its token window. Another observation can resume the focus, and the core receives a notice if an activity was interrupted. If HTTP 403 or 404 recurs across focuses, check model access and `LLM_BASE_URL`.
- **Kernel exit.** A shared failure on the inference endpoint, such as HTTP 401, exhausted account quota, or an incompatible protocol, closes reception and stops the kernel. Correct the reported problem before restarting. When the file service returns 401, the kernel records the rejected upload in the tool result and can continue to the next inference. See [model transport](architecture.md#model-transport) and [file outcomes](content.md#complete-files).

### Recovering from an admission failure

If the core cannot admit an incoming letter within the adapter's request limits, the letter stays unacknowledged in the mailbox. Later correspondence waits behind it. Another accepted observation or a restart can prompt a new attempt. Polling that same letter leaves it pending.

If admission keeps failing, check the focus's interruption reason against the [model request limits](content.md#model-request-checks). To withdraw an oversized letter, stop the kernel, move it out of [eligible intake](#mail-intake), then restart. The kernel rebuilds pending deliveries from the mailbox. You can send a shorter letter with a reference to the original material. See [sharing material to read](usage.md#sharing-material-to-read).

A subscription report that cannot fit stays in the subscription database. Withdrawing the subscription closes it to new reports. The focus still needs enough request space to receive the one already accepted.

## Stopping and restarting

Send `SIGTERM`, or press `Ctrl+C` when running in a terminal, to close reception, cancel session work (including model recovery waits) and host commands, and wait for the runtime's tasks to end. Failure of a required service such as history storage, or an unrecoverable execution error, also stops the runtime. Diagnose the failure and restore any unavailable services before restarting.

Start the executable with the same mail account, `MAIL_ADDRESS`, and subscription store to resume its saved focuses and pending deliveries. Keep the same `DATA_DIR` to preserve feed addresses, descriptions, and messages. Keep access to the configured memory workspace and to host artifacts still needed for the work. If startup reports `SubscriptionCatalogMismatch`, check that the mail account and `DATA_DIR` identify the same instance. When restoring backup data, use a [matched mailbox and subscription store](#backups-and-transfers).

The core receives a fresh startup observation on every restart. A restored activity receives one immediately if it had an unfinished activation or unread internal observations. Other restored activities receive startup with their next event. A letter can appear again if the kernel stopped between saving the observation and acknowledging its mail copy.

Registered wakeups and host completions keep their original receiving sessions across restart. Wakeups whose deadlines passed while the runtime was unavailable become due. Host completions without stored results receive interruption observations with unknown effects; already stored results are preserved.

Host processes and command handles are not restored, and commands are not replayed. Working history preserves confirmed model/tool exchanges; an interrupted operation may have produced effects without a saved result. Ivenna decides how to continue from its history and current state; include known external changes when corresponding about interrupted work. See [after interruption](usage.md#after-interruption) for what continuation means and [startup and interruption](architecture.md#startup-and-interruption) for the reconstruction contract.

### Updating the executable

Before updating across a storage-format change, preserve a [complete backup](#backups-and-transfers) and keep the executables that can read it. To resume [saved history](architecture.md#persistent-working-history), the current kernel requires a mailbox checkpoint that identifies its subscription database. To start fresh with the current build, give it a separate mailbox and `DATA_DIR`.

If an existing deployment sends correspondence, register its intended recipients in `MAIL_CORRESPONDENTS` before starting the updated kernel. See [mail service setup](#mail-service).

If either binary reports `IncompatibleSubscriptionSchema`, check that `DATA_DIR` points to the intended instance and that both the kernel and reporter support its database format. For `SubscriptionCatalogMismatch`, check the [mailbox and database pairing](#stopping-and-restarting).

If startup reports `IncompatibleChannelSchema`, check that `DATA_DIR` points to the intended feed database and that the kernel supports its format. To start a fresh feed catalog, stop the kernel, close its feed readers, and archive the database and any journal files before starting again. See [backups and transfers](#backups-and-transfers).

If you previously tuned `CONTEXT_REQUEST_BYTES` or `CONTEXT_COMPACTION_BYTES`, remove those overrides and choose the current [compaction settings](#context-budgets) for your model and workload.

Older configurations may contain `LLM_MAX_ATTEMPTS`. The kernel now ignores this setting and continues retrying temporary inference failures. `LLM_REQUEST_TIMEOUT_MS` limits each attempt. See [model request settings](#model-requests).

Earlier executables cannot restore a checkpoint whose selected history or pending observations include a `focus_interrupted` event. The current executable requires handovers to include the summary's observation time and sampled state. See [persistent working history](architecture.md#persistent-working-history).

## Data and retention

The deployment chooses storage for the mail account, the memory workspace, and the kernel's local data directory independently. File input also creates uploads in the configured model-service account:

| Location | Contents |
| --- | --- |
| Configured JMAP account | Pending and retired correspondence and callback mail, working-history records and checkpoints, and private markers |
| Configured memory workspace | Shared memory rooms and entries |
| `<DATA_DIR>/host/` | Full stdout and stderr from host commands |
| `<DATA_DIR>/subscriptions.sqlite3` | Subscription registrations, listener cursors, accepted report keys, and reports awaiting history admission |
| `<DATA_DIR>/channels.sqlite3` | Feed addresses, descriptions, closure state, and published messages |
| Configured model-service account | Uploaded files and their service-side parsing results |

Web page snapshots expire on eviction or kernel restart. Previously read passages remain in retained tool results. To reach a new passage after expiry, fetch the original URL again, which may now return a different version. See [web page snapshots](resources.md#web-pages).

Pending subscription reports can accumulate on disk while the kernel is stopped or a focus cannot admit them. The kernel removes each report from the queue once it confirms the observation in the focus's history. Each distinct accepted key stays in the database until withdrawal, even after the queue drains. See [listener retries](subscriptions.md#command-results).

Ivenna moves correspondence and callback copies no longer needed for admission or submission, and history no longer selected for continuation, to Trash. Trash provides the mail service's retention window before deletion. Moving an object to Trash leaves its contents on the service until that policy takes effect; service maintenance controls expiry and physical storage reclamation independently of the kernel.

Ivenna does not monitor quota or evict live records in response to account capacity. A failure in Ivenna's storage maintenance stops the runtime like other storage failures.

### Communication copies

| Copy in Ivenna's account | When Ivenna moves it to Trash |
| --- | --- |
| Incoming message | After saving its complete observation and checkpoint, before reasoning about the request |
| Internal callback | After saving the registered observation in the receiving session's history |
| Outgoing message | At startup or before a mail poll, once the draft is no longer in use for sending. This includes drafts left by interrupted sends. |

Pending input stays available for admission. Internal assignments and unread [activity reports](architecture.md#activity-reports) are kept in working history.

An identifiable callback copy, including one in Trash, preserves the first result for that callback ID. Once the copy expires, a publisher can create another. If the receiving session has already admitted that ID, the kernel acknowledges the new copy without presenting the observation again. See [callback admission](architecture.md#event-sources-and-callback-admission).

Keep original correspondence separately if you need it beyond the Trash retention period. Compaction can replace detailed observations and tool exchanges with a handover. Correspondents manage their own copies.

### Working history

A message with the subject `Ivenna history checkpoint` lists the state the kernel uses to resume its sessions. For each session, `head` points to the latest retained history record and `count` gives the number of records in that chain. Admitted observations and model/tool exchanges live in those separate records, so a whole new exchange can change just a few fields in the checkpoint. The checkpoint also tracks scheduled wakeups, callback registrations, unread activity reports, and how far each focus has read in the subscription database.

Suppose the core receives a letter and the model returns text without calling tools. In an otherwise idle kernel, this normally produces two revisions. The first saves the incoming observation before Ivenna acknowledges the letter. The second saves the model response in the core's history. Sending a reply to the correspondent requires a `send` call.

Ivenna cleans up the history folder at startup and periodically while it runs. Between maintenance passes, several checkpoints can still appear in `Ivenna History`. The kernel selects the candidate marked `ivenna-current` with the highest numeric `X-Ivenna-History-Revision`. If two candidates share that highest revision, restoration fails.

| Location | Contents after maintenance |
| --- | --- |
| `Ivenna History` | Latest checkpoint, selected session histories, and unread activity-report records |
| Trash | Records not selected by the latest checkpoint, and older checkpoints |

Forks store independent copies of inherited history. Include these copies when sizing runtime memory and the mailbox. Compaction replaces older records with a handover and carries forward selected recent records. Previous records can then move to Trash while other sessions keep their own copies.

Each complete model/tool round must fit the mail service's advertised `maxSizeRequest` when saved. Image bytes, file bytes, and encoding overhead count toward that history request, so a result within the [model request limits](content.md#model-request-checks) can still exceed the mailbox limit. A round that cannot fit stops the runtime with `HistoryRecordTooLarge`. Any uploads already completed for that round retain their [remote-file lifecycle](#uploaded-model-files). See the [history storage protocol](architecture.md#history-storage) for the encoding and batching mechanism.

A sleeping activity retains its history even when its context is unloaded. When the activity ends, the next confirmed checkpoint omits its working history, allowing maintenance to move those records to Trash. The activity's messages and ending remain available to the core until they enter the core's history. Shared memory follows its own lifecycle. See [history retention](architecture.md#history-retention) for selection rules.

Unread activity expressions retain each text in order with its original observation time. Ending times are also retained. The core admits reports that fit its ordinary request. Unread reference metadata grows with the backlog, and all unread bodies occupy mailbox storage. Activity messages and endings are outside `MAX_PENDING_EVENTS`, so size runtime memory and mailbox capacity for work that can accumulate before the core next reads it. See [activity reports](architecture.md#activity-reports) for reading and admission behavior.

### Uploaded model files

When an upload returns a usable reference, saved working history includes the original bytes and the service identifier. Later inferences reuse that identifier, including after restart. The [working-history limits](#working-history) apply to the bytes. If an upload may have reached the service but returned no usable reference, the service account can also contain a file whose identifier Ivenna never received. See [file outcomes](content.md#complete-files).

Uploads live at `LLM_BASE_URL` in the account authenticated by `LLM_API_KEY`. Ivenna does not request an upload expiration or delete uploads during compaction or history retirement. Manage them separately under the service's retention policy; see DeepSeek's [Files API](https://api-docs.deepseek.com/guides/files_api/). Deleting an upload still referenced by retained contexts prevents later requests from using that identifier; retained originals are not automatically reuploaded.

Preserve the host artifact or memory entry when it needs to outlive selected working history. See DeepSeek's [file parsing guide](https://api-docs.deepseek.com/guides/document_parsing/) for service behavior and billing.

### Backups and transfers

Back up the mailbox and subscription database together. Startup checks the database identity, which stays the same across snapshots of an instance. Pairing an older mailbox with a newer database can lose a report if the database already removed it and the mailbox snapshot predates its admission.

If taking the backups separately, stop the kernel before saving either store and leave it stopped until both backups finish. Use a SQLite backup of `<DATA_DIR>/subscriptions.sqlite3`. To copy the database files directly, pause independent listeners too and include any SQLite journal files with the database.

For restoration, stop the kernel and listeners before replacing the mailbox and database with their matched copies. Keep the listener programs and their configuration so they can resume collection on the restored subscriptions.

History and callback mail are JMAP Email objects. A backup or transfer used for continuation must preserve the latest checkpoint, every session and outbox record it selects from `Ivenna History`, and pending mail in `Ivenna Callbacks`:

| Applies to | Preserve |
| --- | --- |
| History bodies | Exact plain-text ZON content |
| All selected history objects | Original membership in `Ivenna History`, From and To addresses matching `MAIL_ADDRESS`, `ivenna-state`, and `X-Ivenna-History-Kind` (`record` or `checkpoint`) |
| Records | `ivenna-history-<token>`, `X-Ivenna-History-Key`, and `X-Ivenna-History-Previous` when present |
| Current checkpoint candidates | Membership in `Ivenna History`, `ivenna-current`, and `X-Ivenna-History-Revision` |
| Pending callback mail | Complete text, From and To matching `MAIL_ADDRESS`, membership in `Ivenna Callbacks`, `ivenna-callback`, exact `ivenna-callback-<id>` keyword, and matching `X-Ivenna-Callback-Id` header |

The callback keyword and header contain the internal numeric delivery ID; the checkpoint registration preserves its complete named reference.

Native `Email.id` values may change because restoration uses logical groups, record keys, and callback IDs. See [working history](#working-history) to identify the current checkpoint and [updating the executable](#updating-the-executable) for storage-format compatibility.

Earlier checkpoints are retired through Trash and do not provide rollback. Preserve a complete backup separately if it is needed after the mail service's retention period.

A mailbox backup preserves stored callbacks and wakeup arrangements, not running host processes or their output files. Preserve [host artifacts](#host-output-and-deployment-files) and memory data separately when continued work needs them.

Back up `<DATA_DIR>/channels.sqlite3` with SQLite's backup facilities. For a direct copy, stop the kernel and copy the database and any journal files together. Before replacing the feed database, stop the kernel and close any reader connections. Feed addresses and message sequences belong to that catalog. Replacing the catalog or restoring an older snapshot can reuse addresses and sequences from discarded data. Reconcile saved addresses and reader cursors before resuming. See [SQLite backups](https://www.sqlite.org/backup.html).

### Feed storage

Use SQLite 3.37 or later for local readers of `<DATA_DIR>/channels.sqlite3`. Open a read-only connection on the kernel host and query the documented feed views. In WAL mode, the reader needs access to the existing `-wal` and `-shm` files or directory permission to create them. Grant database access to readers authorized for the whole catalog. Use a relay for selected feeds or remote consumers. See [reading feeds](communication.md#reading-feeds), [SQLite strict tables](https://www.sqlite.org/stricttables.html), and [read-only WAL access](https://www.sqlite.org/wal.html#read_only_databases).

Closing a feed preserves its description and messages. The database grows with output and has no automatic expiry. See [backups and transfers](#backups-and-transfers).

### Host output and deployment files

Set `DATA_DIR` to writable storage that supports ordinary files and subdirectories. An absolute path keeps output storage stable across changes to the kernel's startup directory. Launching a command creates any missing output directories with private permissions.

Host output files remain available after the command and activity session end. Retained material can refer to their paths, so preserve files still needed for continued work. Automatic output cleanup is not implemented.

Keep provisioning files, credentials, and SSH keys with the deployment configuration. The [local development data reference](../dev/README.md#development-data) lists the Compose volumes and files used by the supplied setup.
