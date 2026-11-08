# Running Ivenna

The Ivenna kernel connects to a model service, a mail service, and an SSH workspace for autonomous memory. This guide covers runtime requirements, configuration, startup, and data retention. For the supplied local environment, follow the [local development guide](../dev/README.md).

## Runtime requirements

Use a built `ivenna` executable, `/bin/sh`, and an OpenSSH client in the kernel's execution environment. See the [build instructions](development.md#repository-and-build) to build from source. Host commands run as the kernel's OS account and use the files and programs available in that environment.

Terminal mode additionally requires Linux 5.3 or newer with `pidfd_open`, `pidfd_send_signal`, and `TIOCGPTPEER` available, readable `/proc`, a working `/dev/ptmx` backed by devpts, and util-linux `setsid` at `/usr/bin/setsid`. These facilities establish the controlling terminal and allow cleanup of its session's foreground and background jobs. Batch and pipe modes do not require this terminal transport.

The application uses the Responses adapter with DeepSeek as the default model service. Supply its API key, or configure a Responses-compatible endpoint and model through `LLM_BASE_URL` and `LLM_MODEL`. The kernel also needs access to the [mail service](#mail-service) and [memory service](#memory-service). The mail receiving boundary needs access to the kernel's [reception status](#service-status-and-reception).

## Configuration

The kernel reads its process environment. Supply the settings through the deployment's launcher or service manager. To apply changes, stop the kernel and start it with the updated environment.

Set connection addresses, identities, and paths for the chosen deployment. The table records the current executable's defaults.

| Variable | Purpose | Default when unset |
| --- | --- | --- |
| `LLM_API_KEY` | Model API key | Required |
| `LLM_BASE_URL` | Model API base URL | `https://api.deepseek.com` |
| `LLM_MODEL` | Model name | `deepseek-flash` |
| `LLM_MAX_OUTPUT_TOKENS` | Maximum output tokens per response, including reasoning tokens | `8192` |
| `LLM_CORE_REASONING_EFFORT` | Reasoning effort for ordinary core requests | `low` |
| `LLM_ACTIVITY_REASONING_EFFORT` | Reasoning effort for ordinary activity-session requests | `high` |
| `SERVICE_ADDRESS` | HTTP health and reception-readiness listener | `0.0.0.0:8090` |
| `MAIL_SESSION_URL` | JMAP session URL | `http://127.0.0.1:8088/jmap/session` |
| `MAIL_ADDRESS` | Kernel address and sending identity; its domain resolves correspondent IDs | Required |
| `MAIL_USERNAME` | Mail login | Required for username/password authentication |
| `MAIL_PASSWORD` | Mail password | Required for username/password authentication |
| `MAIL_AUTHORIZATION` | Complete HTTP Authorization header | Unset; use username/password |
| `MAIL_POLL_INTERVAL_MS` | Delay between mail polls | `2000` |
| `MAX_SESSIONS` | Maximum registered session identities, including sleeping sessions and the core | `128` |
| `MAX_PENDING_EVENTS` | Maximum ordinary accepted events buffered per session; excludes startup and activity reports | `64` |
| `MAX_HOST_COMMANDS` | Maximum live host commands across all activity sessions | `8` |
| `CONTEXT_REQUEST_BYTES` | Maximum complete serialized ordinary model request | `65536` |
| `CONTEXT_COMPACTION_BYTES` | Maximum complete serialized summary request | `131072` |
| `DATA_DIR` | Base directory for host command output in the kernel filesystem | `.ivenna` |
| `MEMORY_SSH_TARGET` | Memory SSH target | `ivenna-memory` |
| `MEMORY_SSH_CONFIG` | Dedicated SSH configuration file | Standard OpenSSH configuration |

`MAIL_AUTHORIZATION` takes precedence over username/password authentication. `SERVICE_ADDRESS` must contain a literal IP address and a nonzero port; keep the [mail readiness policy](#service-status-and-reception) aligned when changing it. Numeric kernel settings must be positive.

Core and activity sessions use the same configured model and output-token limit. Reasoning effort values are `none`, `minimal`, `low`, `medium`, `high`, `xhigh`, and `max`; choose values supported by the configured model service. Compaction always uses `high` reasoning effort with no tools, independently of the ordinary session settings. Reasoning tokens consume the output allowance; a response reported as incomplete fails model execution and stops the runtime.

`MAX_SESSIONS` counts the core and all registered activities, including those asleep. Startup fails if saved identities exceed it; with a value of `1`, only the core fits. New forks fail at capacity, while existing sessions remain addressable. Activity completion releases a slot. Ready sessions can advance concurrently. Host commands have a separate live limit and [handle retention lifecycle](host.md#command-lifetimes). The session and command defaults are tuning starting points; size them for the workload and resources available.

`MAX_PENDING_EVENTS` limits ordinary accepted events buffered for a session. Startup observations, passive activity expressions, and activity endings are excluded. Opening a focus and admitting its ending do not need space in the core's ordinary event queue. Correspondence and callback mail have independent intake allowances and stay in their durable sources when their destination is full. Focus messages use this ordinary allowance and return `focus_queue_full` when the recipient cannot accept them. Capacity and polling can delay scheduled work.

Request byte limits cover the complete encoded payload, including the repeated runtime snapshot, history, tools, and images. They are not token estimates. Callback registrations have no separate count limit; a larger callback list or roster leaves less room for history and observations. These budgets also apply to an activity's inherited history. A generated handover has no separate byte limit, but the complete replacement request must fit.

Compaction allows one further inference if the first handover has missing or blank text, includes tool calls, or leaves the replacement request over budget. If both attempts fail, or a summary request itself exceeds `CONTEXT_COMPACTION_BYTES`, the runtime stops with its earlier history and unadmitted observations intact. Input that still cannot fit after compaction fails with `ContextBudgetExhausted`. See [context budgets](architecture.md#bounded-model-context).

Relative `DATA_DIR` and `MEMORY_SSH_CONFIG` paths resolve from the kernel's startup directory.

## Mail service

Use a dedicated account as programmatic storage for Ivenna's communication records, callback inbox, and working history, with JMAP Mail and Submission capabilities and a sending identity matching `MAIL_ADDRESS`. The account needs a Drafts folder and permission to create and move messages and update private keywords. Ivenna creates the top-level `Ivenna Callbacks` and `Ivenna History` folders and a mailbox with role `trash` when missing; the dedicated folders have no special mail role. The account must permit folder creation.

Set the account's `MAIL_SESSION_URL`, `MAIL_ADDRESS`, and authentication settings in the kernel's environment. The adapter uses the domain of `MAIL_ADDRESS` to resolve correspondent IDs. Use separate correspondent accounts in that same domain to send messages to Ivenna and receive its outgoing mail. For `MAIL_ADDRESS=ivenna@ivenna.test`, the correspondent address `operator@ivenna.test` supplies the ID `operator`. Choose the domain for your deployment.

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

Prepare the configured services and supply the kernel's environment, then run the built executable from the directory chosen for host work. For example, with the executable installed at `/path/to/ivenna`:

```sh
cd /path/to/workspace
/path/to/ivenna
```

The kernel's startup directory becomes the default directory for host commands. The executable embeds its model-facing resources and can run independently of the source checkout.

Use one kernel per mailbox. Startup discovers the account, checks memory availability, restores saved sessions or creates the core, and completes storage maintenance before opening reception. Check [reception readiness](#service-status-and-reception) before following the [usage guide](usage.md) to send a message. Diagnostics are written to the kernel's standard error; service diagnostics follow each service's configuration.

Startup reads and validates all selected session history, including sleeping sessions. Allow for the resulting I/O and temporary memory use when sizing the deployment. See [history restoration](architecture.md#saving-and-restoration) for context loading behavior.

## Service status and reception

The HTTP listener at `SERVICE_ADDRESS` exposes:

| Endpoint | Response |
| --- | --- |
| `GET /healthz` | `200 OK` for listener health |
| `GET /readyz` | `200 OK` with `X-Ivenna-Ready: true` when reception is open; otherwise `503 Service Unavailable` |

Reception opens after initialization and initial storage maintenance. Startup model work runs with reception open. Reception closes when the runtime stops or fails. These endpoints report lifecycle state; they do not probe mail or memory on each request. For a listener reachable at `127.0.0.1:8090`, check the current state with:

```sh
curl --include http://127.0.0.1:8090/readyz
```

Configure the mail receiving boundary to check the readiness header at an address it can reach and reject incoming traffic when the header is absent, including when the endpoint cannot be reached. Apply the policy to every receiving address and delivery path used for correspondence. The [local Stalwart setup](../dev/README.md#configuring-mail) demonstrates an SMTP recipient check.

Readiness describes the kernel's reception state when queried. It reserves no processing capacity, and the runtime can stop after a successful check or accepted delivery. The kernel continues to read [pending correspondence](#mail-intake) already present in its account.

## Stopping and restarting

Send `SIGTERM`, or press `Ctrl+C` when running in a terminal, to close reception, cancel session work and host commands, and wait for the runtime's tasks to end. Infrastructure and execution failures also stop the runtime. Diagnose the failure and restore any unavailable services before restarting.

Start the executable again with the same mail account and `MAIL_ADDRESS` to load its latest saved working contexts. Working history survives independently of the previous host's `DATA_DIR`. Keep access to the configured memory workspace and to host artifacts still needed for the work.

The core and sessions with interrupted activations or unread internal observations receive fresh startup observations. Other activity sessions remain asleep until an event arrives.

Registered wakeups and host completions keep their original receiving sessions across restart. Wakeups whose deadlines passed while the runtime was unavailable become due. Host completions without stored results receive interruption observations with unknown effects; already stored results are preserved.

Host processes and command handles are not restored, and commands are not replayed. Working history preserves confirmed model/tool exchanges; an interrupted operation may have produced effects without a saved result. Ivenna decides how to continue from its history and current state; include known external changes when corresponding about interrupted work. See [after interruption](usage.md#after-interruption) for what continuation means and [startup and interruption](architecture.md#startup-and-interruption) for the reconstruction contract.

### Recovering from an admission failure

When an incoming message fails admission with `ContextBudgetExhausted`, it remains unacknowledged. On restart, the runtime retries admission from saved history; a new summary may produce a request that fits. If the limit recurs, review the [request budgets](#configuration) and [eligible pending correspondence](#mail-intake). Adjust the budgets or remove a message that cannot fit from eligible intake as appropriate.

### Updating the executable

Restoration requires a [history format](architecture.md#persistent-working-history) understood by the executable. The prototype provides no compatibility layer or automatic migration for storage-format changes. Before applying such an update to an existing deployment, preserve a [complete backup](#backups-and-transfers) and retain a compatible executable, or use a separate dedicated mailbox for the new format. Incompatible history fails startup; updating the executable does not clear or migrate the account.

The current history format preserves named focus and callback references alongside internal routing identities and includes the next command number in the checkpoint. Activity observations carry `from_focus`, timestamped `messages`, and `ended_at_unix_ms`; retained records and handovers identify their producing or receiving `focus_id`. Checkpoints or observations using earlier shapes are incompatible with this executable.

## Data and retention

The deployment chooses storage for the mail account, the memory workspace, and the kernel's local data directory independently:

| Location | Contents |
| --- | --- |
| Configured JMAP account | Pending and retired correspondence and callback mail, working-history records and checkpoints, and private markers |
| Configured memory workspace | Shared memory rooms and entries |
| `<DATA_DIR>/host/` | Full stdout and stderr from host commands |

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

Forks store independent copies of inherited history; include these copies when sizing the mailbox. Compaction replaces only that session's selection, allowing its previous records to move to Trash while other sessions keep their own copies.

A sleeping activity retains its history even when its context is unloaded. When the session ends, the next confirmed checkpoint omits its working history, allowing maintenance to move those records to Trash. Its unread reports remain selected independently of that session until the core admits them. Admitted reports belong to the core's history, and shared memory follows its own lifecycle. See [history retention](architecture.md#history-retention) for selection rules.

Unread activity expressions retain every new text in order with its original observation time; they are not replaced with the latest text. Ending times are also retained. The core admits reports within its ordinary request budget. Unread reference metadata grows with the backlog, and all unread bodies occupy mailbox storage. Activity messages and endings are outside `MAX_PENDING_EVENTS`, so size runtime memory and mailbox capacity for work that can accumulate before the core next reads it. See [activity reports](architecture.md#activity-reports) for reading and admission behavior.

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

`DATA_DIR` selects the base directory for host output in the kernel's filesystem. Launching a command creates any missing output directories with private permissions. Changing it selects where new output is written; it does not move existing files, mailbox history, memory, or SSH configuration.

Use writable storage that supports ordinary files and subdirectories.

Host output files remain available after the command and activity session end. Retained material can refer to their paths, so preserve files still needed for continued work. Automatic output cleanup is not implemented.

Keep provisioning files, credentials, and SSH keys with the deployment configuration. The [local development data reference](../dev/README.md#development-data) lists the Compose volumes and files used by the supplied setup.
