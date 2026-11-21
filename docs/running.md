# Running Ivenna

The Ivenna kernel connects to a model service, a mail service, and an SSH workspace for autonomous memory. This guide covers runtime requirements, configuration, startup, and data retention. For the supplied local environment, follow the [local development guide](../dev/README.md).

## Runtime requirements

Use a built `ivenna` executable, `/bin/sh`, and an OpenSSH client in the kernel's execution environment. See the [build instructions](development.md#repository-and-build) to build from source. Host commands run as the kernel's OS account and use the files and programs available in that environment.

Terminal mode additionally requires Linux 5.3 or newer with `pidfd_open`, `pidfd_send_signal`, and `TIOCGPTPEER` available, readable `/proc`, a working `/dev/ptmx` backed by devpts, and util-linux `setsid` at `/usr/bin/setsid`. These facilities establish the controlling terminal and allow cleanup of its session's foreground and background jobs. Batch and pipe modes do not require this terminal transport.

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
| `CONTEXT_REQUEST_BYTES` | Maximum complete serialized ordinary model request | `1048576` (1 MiB) |
| `CONTEXT_COMPACTION_BYTES` | Maximum complete serialized summary request | `2097152` (2 MiB) |
| `SERVICE_ADDRESS` | HTTP health and reception-readiness listener | `0.0.0.0:8090` |
| `MAIL_SESSION_URL` | JMAP session URL | `http://127.0.0.1:8088/jmap/session` |
| `MAIL_ADDRESS` | Kernel address and sending identity; its domain resolves correspondent IDs | Required |
| `MAIL_USERNAME` | Mail login | Required for username/password authentication |
| `MAIL_PASSWORD` | Mail password | Required for username/password authentication |
| `MAIL_AUTHORIZATION` | Complete HTTP Authorization header | Unset; use username/password |
| `MAIL_POLL_INTERVAL_MS` | Delay between mail polls | `2000` |
| `MAX_SESSIONS` | Maximum registered session identities, including sleeping sessions and the core | `128` |
| `MAX_PENDING_EVENTS` | Maximum ordinary accepted events buffered per session | `64` |
| `MAX_HOST_COMMANDS` | Maximum live host commands across all activity sessions | `8` |
| `DATA_DIR` | Persistent base directory for host command output in the kernel filesystem | Required |
| `MEMORY_SSH_TARGET` | Memory SSH target | `ivenna-memory` |
| `MEMORY_SSH_CONFIG` | Dedicated SSH configuration file | Standard OpenSSH configuration |

`MAIL_AUTHORIZATION` takes precedence over username/password authentication. `SERVICE_ADDRESS` must contain a literal IP address and a nonzero port; keep the [mail readiness policy](#service-status-and-reception) aligned when changing it.

Numeric kernel settings must be positive. Relative `DATA_DIR` and `MEMORY_SSH_CONFIG` paths resolve from the kernel's startup directory.

### Model requests

Core and activity sessions share the configured model and output-token limit. `LLM_MAX_OUTPUT_TOKENS` covers reasoning, assistant text, and tool-call arguments.

Choose an ordinary reasoning effort for each role from the values supported by your model service. Ivenna accepts `none`, `minimal`, `low`, `medium`, `high`, `xhigh`, and `max`. Compaction always uses `high` with no tools.

`LLM_REQUEST_TIMEOUT_MS` applies separately to each inference attempt, including compaction. A temporary outage can therefore delay a decision beyond this timeout. For each file upload, the timeout covers the entire negotiation. See [when model work stalls](#when-model-work-stalls) and [file outcomes](content.md#complete-files).

### Context budgets

`CONTEXT_REQUEST_BYTES` limits ordinary model requests, and `CONTEXT_COMPACTION_BYTES` limits summary requests. Both cover the complete encoded payload, including retained history, runtime state, tool declarations, inline images, and file references. An activity's inherited history consumes the same request space as its subsequent exchanges.

Choose both byte budgets and the output-token limit together for the configured model and workload. The ordinary budget controls how much history can accumulate before a handover; the larger compaction budget leaves room to summarize history after a complete model/tool round crosses that limit. Byte counts are not token estimates; input and output must also fit the model's token limits.

Handovers carry pending callback references and, for the core, existing activity references alongside the generated summary. Callback registrations have no separate count limit, so pending work can consume a growing share of the budget. A handover has no separate byte limit; the complete continuation request must fit the ordinary budget.

Individual tool results can meet their [content limits](content.md#model-request-checks) while a large batch or inline image exceeds the context budgets. Inline images include base64 encoding overhead. Reduce their size or use image URL references when that overhead would exceed the request budget.

For files, the byte budgets measure identifiers and source descriptions. The model service expands those references, so a request within Ivenna's budget can still exceed the service's context limits. See DeepSeek's [file parsing guide](https://api-docs.deepseek.com/guides/document_parsing/) and [when model work stalls](#when-model-work-stalls).

If a summary request exceeds its budget or compaction cannot fit the next ordinary request, the affected focus waits with its earlier history and unadmitted observations intact. See [recovering from an admission failure](#recovering-from-an-admission-failure) and the [compaction mechanism](architecture.md#bounded-model-context).

### Session and command capacity

`MAX_SESSIONS` counts the core and all registered activities, including those asleep. Startup fails if saved identities exceed it; with a value of `1`, only the core fits. New forks fail at capacity, while existing sessions remain addressable. Activity completion releases a slot. Ready sessions can advance concurrently. Host commands have a separate live limit and [handle retention lifecycle](host.md#command-lifetimes). The session and command defaults are tuning starting points; size them for the workload and resources available.

`MAX_PENDING_EVENTS` counts correspondence, callbacks, assignments, and focus messages buffered for a session. Startup observations, activity expressions, endings, and notices of activity interruption are exempt. Correspondence and callback mail have independent intake allowances and stay in their mailboxes when their destination is full. A focus message returns `focus_queue_full` when the recipient cannot accept it. Capacity and polling can delay scheduled work.

## Changing the model

Retained history can include native model output and reasoning data supplied by the model adapter, plus file identifiers supplied by the model service. A replacement service and model must accept those items as well as the configured tools and reasoning settings. File identifiers also require access to the account that owns the uploads. The runtime does not translate retained model output, transfer uploaded files between services, or verify in advance that a replacement model can consume them. Establish compatibility before resuming retained work with the replacement model.

To apply the change, [stop the kernel](#stopping-and-restarting), update `LLM_MODEL` and any changed service settings, then restart. Keep the existing mail account, `MAIL_ADDRESS`, and memory workspace to retain the material needed for continuation.

## Mail service

Use a dedicated account as programmatic storage for Ivenna's communication records, callback inbox, and working history, with JMAP Mail and Submission capabilities and a sending identity matching `MAIL_ADDRESS`. The account needs a Drafts folder and permission to create and move messages and update private keywords. Ivenna creates the top-level `Ivenna Callbacks` and `Ivenna History` folders and a mailbox with role `trash` when missing; the dedicated folders have no special mail role. The account must permit folder creation.

Set the account's `MAIL_SESSION_URL`, `MAIL_ADDRESS`, and authentication settings in the kernel's environment. The adapter uses the domain of `MAIL_ADDRESS` to resolve correspondent IDs. Use separate correspondent accounts in that same domain to send messages to Ivenna and receive its outgoing mail. For `MAIL_ADDRESS=ivenna@ivenna.test`, the correspondent address `operator@ivenna.test` supplies the ID `operator`. Choose the domain for your deployment.

Each JMAP HTTP exchange has a fixed 60-second time limit covering connection, request writing, and response reading. Timeout or cancellation stops the exchange; requests are not automatically retried. An interrupted mailbox mutation or message submission may already have taken effect, so its effects can remain uncertain when the runtime stops.

Use the [supported email addresses](communication.md#current-email-addressing). Changing `MAIL_ADDRESS` to another domain changes how retained correspondent IDs resolve.

For correspondence, require authenticated submission and From addresses the submitting account is authorized to use. Ivenna relies on these checks when presenting correspondent IDs. Apply them and the [reception-readiness policy](#service-status-and-reception) to every receiving path used for correspondence. The [local mail setup](../dev/README.md#configuring-mail) supplies an SMTP configuration.

Wakeup and host completion callbacks are created directly through JMAP in `Ivenna Callbacks`. The existing account and receiving policy need no additional alias, account, or SMTP exception. Keep pending callback mail in this folder with its private metadata intact: moving it elsewhere removes it from callback intake, and the runtime does not move it back. Stored callbacks remain available while the kernel is stopped. See [callback observations](attention.md#callback-observations) for the delivery contract.

Configure automatic Trash expiry and cleanup of unreferenced storage in the mail service. These processes must continue independently of the kernel. Choose retention with the provider's full policy scope in mind: Trash and Junk policies can also remove ordinary mail. The [local Stalwart setup](../dev/README.md#configuring-mail) provides a concrete configuration.

The [intake rules](#mail-intake) also apply to existing correspondence in the account. Working history shares the account's storage capacity; [data and retention](#data-and-retention) explains its folder lifecycle and backup requirements.

### Mail intake

The kernel reads correspondence awaiting durable admission across the account's mail folders, including the mail client's ordinary Archive folder. `Ivenna Callbacks`, `Ivenna History`, Drafts, Junk, and Trash are excluded from ordinary correspondence, along with drafts and records carrying private callback, outgoing, or history-state markers. The callback inbox has its own admission path; these records do not become correspondence.

Incoming mail must have at least one From address, and every such address must map to a supported ID in the configured domain. The adapter presents the corresponding IDs and complete supported text as an observation. Messages with missing, cross-domain, or unsupported From addresses are excluded from intake. Messages without a complete supported body produce a diagnostic and are skipped. These copies remain unchanged.

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

Prepare the configured services and supply the required [environment settings](#configuration). For an executable installed at `/path/to/ivenna`, choose the host workspace and output storage when starting it:

```sh
cd /path/to/workspace
export DATA_DIR=/path/to/instance/data
/path/to/ivenna
```

The kernel's startup directory becomes the default directory for host commands. The executable embeds its model-facing resources and can run independently of the source checkout.

Run one kernel per mailbox. The kernel binds `SERVICE_ADDRESS` before accessing the account. If the address is in use, startup exits. On Linux, an `AddressInUse` error just after an upgrade can persist until the older executable's connections leave `TIME_WAIT`.

The kernel initializes mail, checks memory, restores saved sessions or creates the core, and completes storage maintenance before opening reception. Check [reception readiness](#service-status-and-reception) before [sending a message](usage.md#sending-a-request). The kernel writes diagnostics to standard error.

Startup reads and validates all selected session history, including sleeping sessions. Allow for the resulting I/O and temporary memory use when sizing the deployment. See [history restoration](architecture.md#saving-and-restoration) for context loading behavior.

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

### When model work stalls

Look for `retrying inference` or `interrupted` in the kernel's standard error. Both messages identify the affected focus.

- **Temporary outage.** The kernel retries the same inference, including a request for a compaction summary. Each retry logs its delay. The first wait is 250–500 milliseconds. The range doubles after each failure up to 2.5–5 minutes. A longer delay requested by the service in `Retry-After` takes precedence. Retries reuse completed tool results. A lost model response can still incur charges.
- **Interrupted focus.** A rejected request or an incomplete or invalid generation leaves that focus's history intact. Another observation can resume its work, and the core receives a notice if an activity was interrupted. A 403 or 404 can refer to a resource used by one request. If either status recurs across focuses, check model access and `LLM_BASE_URL`.
- **Kernel exit.** A shared failure on the inference endpoint, such as HTTP 401, exhausted account quota, or an incompatible protocol, closes reception and stops the kernel. Correct the reported problem before restarting. When the file service returns 401, the kernel records the rejected upload in the tool result and can continue to the next inference. See [model transport](architecture.md#model-transport) and [file outcomes](content.md#complete-files).

### Recovering from an admission failure

If the core cannot fit an incoming letter and its context in a model request, the letter stays unacknowledged in the mailbox. Later correspondence waits behind it. Another accepted observation or a restart can prompt a new attempt. Polling that same letter leaves it pending.

If admission keeps failing, check the [context budgets](#context-budgets) and restart with budgets suitable for the model and the letter. To withdraw the letter instead, stop the kernel, move it out of [eligible intake](#mail-intake), then restart. The kernel rebuilds pending deliveries from the mailbox.

## Stopping and restarting

Send `SIGTERM`, or press `Ctrl+C` when running in a terminal, to close reception, cancel session work (including model recovery waits) and host commands, and wait for the runtime's tasks to end. Failure of a required service such as history storage, or an unrecoverable execution error, also stops the runtime. Diagnose the failure and restore any unavailable services before restarting.

Start the executable again with the same mail account and `MAIL_ADDRESS` to load its latest saved working contexts. Working history survives independently of the previous host's `DATA_DIR`. Keep access to the configured memory workspace and to host artifacts still needed for the work.

The core and sessions with interrupted activations or unread internal observations receive fresh startup observations. Other activity sessions remain asleep until an event arrives. If the kernel saved a letter just before stopping and its acknowledgement is still pending, the letter can appear again.

Registered wakeups and host completions keep their original receiving sessions across restart. Wakeups whose deadlines passed while the runtime was unavailable become due. Host completions without stored results receive interruption observations with unknown effects; already stored results are preserved.

Host processes and command handles are not restored, and commands are not replayed. Working history preserves confirmed model/tool exchanges; an interrupted operation may have produced effects without a saved result. Ivenna decides how to continue from its history and current state; include known external changes when corresponding about interrupted work. See [after interruption](usage.md#after-interruption) for what continuation means and [startup and interruption](architecture.md#startup-and-interruption) for the reconstruction contract.

### Updating the executable

Restoration requires a [history format](architecture.md#persistent-working-history) understood by the executable. The prototype provides no compatibility layer or automatic migration for storage-format changes. Before applying such an update to an existing deployment, preserve a [complete backup](#backups-and-transfers) and retain a compatible executable, or use a separate dedicated mailbox for the new format. Incompatible history fails startup; updating the executable does not clear or migrate the account.

Older configurations may contain `LLM_MAX_ATTEMPTS`. The kernel now ignores this setting and continues retrying temporary inference failures. `LLM_REQUEST_TIMEOUT_MS` limits each attempt. See [model request settings](#model-requests).

Earlier executables cannot restore a checkpoint whose selected history or pending observations include a `focus_interrupted` event. The current executable requires handover records to include the state sampled for the summary and its observation time. Earlier handovers without those fields fail restoration. See [persistent working history](architecture.md#persistent-working-history).

## Data and retention

The deployment chooses storage for the mail account, the memory workspace, and the kernel's local data directory independently. File input also creates uploads in the configured model-service account:

| Location | Contents |
| --- | --- |
| Configured JMAP account | Pending and retired correspondence and callback mail, working-history records and checkpoints, and private markers |
| Configured memory workspace | Shared memory rooms and entries |
| `<DATA_DIR>/host/` | Full stdout and stderr from host commands |
| Configured model-service account | Uploaded files and their service-side parsing results |

Ivenna moves correspondence and callback copies no longer needed for admission or submission, and history no longer selected for continuation, to Trash. Trash provides the mail service's retention window before deletion. Moving an object to Trash leaves its contents on the service until that policy takes effect; service maintenance controls expiry and physical storage reclamation independently of the kernel.

Ivenna does not monitor quota or evict live records in response to account capacity. A failure in Ivenna's storage maintenance stops the runtime like other storage failures.

### Communication copies

Ivenna releases a communication copy when its observation has been durably admitted or submission no longer needs the copy:

| Copy | Retirement |
| --- | --- |
| Incoming message | After its complete observation and checkpoint are saved, acknowledgement moves Ivenna's incoming copy to Trash |
| Internal callback | After durable admission of the registered observation, acknowledgement moves its mail copy to Trash |
| Outgoing message | Created in Drafts; confirmed submission moves the copy to Trash without cancelling delivery |
| Interrupted outgoing copy | Initialization or the next poll moves the runtime's leftover outgoing copy to Trash |

Acknowledgement confirms durable admission, not completion of the requested work. Pending supported input remains available for admission. Internal assignments are saved with session work. Activity reports are retained as outbox history records until core admission; they are not separate correspondence copies.

Publisher first-result preservation lasts while an identifiable callback copy remains, including in Trash. Losing that copy permits new publication, but saved [admission deduplication](architecture.md#event-sources-and-callback-admission) still prevents another observation for a consumed ID.

The mail account is not a permanent transcript: original copies expire under the Trash policy, and compaction can replace detailed observations and tool exchanges with a handover. Preserve original correspondence separately when it needs a longer lifetime. A correspondent's own account and received copies remain outside Ivenna's copy management.

### Working history

The latest checkpoint selects the histories needed to continue all registered sessions, including sleeping sessions whose contexts are unloaded, and retains callback registrations with their sources, scheduled wakeups, and the unread activity-report outbox. Ivenna classifies its saved history at startup and periodically during operation, placing records according to that checkpoint:

| Location | Contents |
| --- | --- |
| `Ivenna History` | Latest checkpoint, selected session histories, and unread activity-report records |
| Trash | Records not selected by the latest checkpoint, and older checkpoints |

Forks store independent copies of inherited history; include these copies when sizing runtime memory and the mailbox. Compaction replaces detailed observations and exchanges with a handover containing the generated summary and sampled runtime state. This changes only that session's selected history, allowing its previous records to move to Trash while other sessions keep their own copies.

Each complete model/tool round must fit the mail service's advertised `maxSizeRequest` when saved. File bytes and encoding overhead count toward that history request, so meeting the [source limits](content.md#automatic-classification) does not guarantee that a file or batch can be saved. A round that cannot fit stops the runtime with `HistoryRecordTooLarge`; any uploads already completed for that round retain their [remote-file lifecycle](#uploaded-model-files). See the [history storage protocol](architecture.md#history-storage) for the encoding and batching mechanism.

A sleeping activity retains its history even when its context is unloaded. When the session ends, the next confirmed checkpoint omits its working history, allowing maintenance to move those records to Trash. Its unread reports remain selected independently of that session until the core admits them. Admitted reports belong to the core's history, and shared memory follows its own lifecycle. See [history retention](architecture.md#history-retention) for selection rules.

Unread activity expressions retain every new text in order with its original observation time; they are not replaced with the latest text. Ending times are also retained. The core admits reports within its ordinary request budget. Unread reference metadata grows with the backlog, and all unread bodies occupy mailbox storage. Activity messages and endings are outside `MAX_PENDING_EVENTS`, so size runtime memory and mailbox capacity for work that can accumulate before the core next reads it. See [activity reports](architecture.md#activity-reports) for reading and admission behavior.

### Uploaded model files

When an upload returns a usable reference, saved working history includes the original bytes and the service identifier. Later inferences reuse that identifier, including after restart. The [working-history limits](#working-history) apply to the bytes. If an upload may have reached the service but returned no usable reference, the service account can also contain a file whose identifier Ivenna never received. See [file outcomes](content.md#complete-files).

Uploads live at `LLM_BASE_URL` in the account authenticated by `LLM_API_KEY`. Ivenna does not request an upload expiration or delete uploads during compaction or history retirement. Manage them separately under the service's retention policy; see DeepSeek's [Files API](https://api-docs.deepseek.com/guides/files_api/). Deleting an upload still referenced by retained contexts prevents later requests from using that identifier; retained originals are not automatically reuploaded.

Preserve the host artifact or memory entry when it needs to outlive selected working history. See DeepSeek's [file parsing guide](https://api-docs.deepseek.com/guides/document_parsing/) for service behavior and billing.

### Backups and transfers

History and callback mail are JMAP Email objects. A backup or transfer used for continuation must preserve the latest checkpoint, every session and outbox record it selects from `Ivenna History`, and pending mail in `Ivenna Callbacks`:

| Applies to | Preserve |
| --- | --- |
| History bodies | Exact plain-text ZON content |
| All selected history objects | Original membership in `Ivenna History`, From and To addresses matching `MAIL_ADDRESS`, `ivenna-state`, and `X-Ivenna-History-Kind` (`record` or `checkpoint`) |
| Records | `ivenna-history-<token>`, `X-Ivenna-History-Key`, and `X-Ivenna-History-Previous` when present |
| Current checkpoint candidates | Membership in `Ivenna History`, `ivenna-current`, and `X-Ivenna-History-Revision` |
| Pending callback mail | Complete text, From and To matching `MAIL_ADDRESS`, membership in `Ivenna Callbacks`, `ivenna-callback`, exact `ivenna-callback-<id>` keyword, and matching `X-Ivenna-Callback-Id` header |

The callback keyword and header contain the internal numeric delivery ID; the checkpoint registration preserves its complete named reference.

If an interrupted save leaves several current checkpoint candidates, the runtime selects the highest numeric revision. Native `Email.id` values may change because restoration uses logical groups, record keys, and callback IDs. An import that preserves bodies alone is insufficient. See [updating the executable](#updating-the-executable) for storage-format compatibility.

Earlier checkpoints are retired through Trash and do not provide rollback. Preserve a complete backup separately if it is needed after the mail service's retention period.

A mailbox backup preserves stored callbacks and wakeup arrangements, not running host processes or their output files. Preserve [host artifacts](#host-output-and-deployment-files) and memory data separately when continued work needs them.

### Host output and deployment files

Set `DATA_DIR` to writable storage that supports ordinary files and subdirectories. An absolute path keeps output storage stable across changes to the kernel's startup directory. Launching a command creates any missing output directories with private permissions.

Host output files remain available after the command and activity session end. Retained material can refer to their paths, so preserve files still needed for continued work. Automatic output cleanup is not implemented.

Changing `DATA_DIR` selects where new output is written; it does not move existing files, mailbox history, memory, or SSH configuration.

Keep provisioning files, credentials, and SSH keys with the deployment configuration. The [local development data reference](../dev/README.md#development-data) lists the Compose volumes and files used by the supplied setup.
