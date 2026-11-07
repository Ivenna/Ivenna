# Architecture

This guide describes Ivenna's current implementation: package responsibilities, execution, and service and storage protocols. The kernel retains working histories across restarts and constructs fresh execution state on startup. The application assembles the runtime and exposes health and reception status.

The [design intent](design.md) sets the behavioral goals and interface principles. The [input contract](input.md) defines model-facing records and current requests, [communication](communication.md) defines outgoing messages, and the [usage guide](usage.md) explains correspondence with Ivenna.

## Responsibilities

| Unit | Responsibility |
| --- | --- |
| [apps/ivenna](../apps/ivenna) | Configure and assemble the runtime, serve HTTP status, and own process startup and shutdown |
| [apps/memory](../apps/memory) | Serve memory operations over SSH and own workspace files, capacity enforcement, and locking |
| [packages/agent](../packages/agent/src/root.zig) | Coordinate sessions, activations, forks, and retained history; own model-input rendering, execution policy, and model-facing resources |
| [packages/agent_contracts](../packages/agent_contracts/src/root.zig) | Define the communication, history storage, and capability contracts shared by execution and concrete implementations |
| [packages/email](../packages/email/src/root.zig) | Own native addressing, message projection, submission, storage, and retention behind the communication and history contracts |
| [packages/responses](../packages/responses/src/root.zig) | Encode and measure model requests, decode Responses output, and apply model content limits |
| [packages/host](../packages/host/src/root.zig) | Define host tools and own shell execution, process cleanup, logs, and returned output |
| [packages/memory](../packages/memory/src/root.zig) | Define memory tools and translate their operations and results through the SSH service protocol |
| [packages/content](../packages/content/src/root.zig) | Define tool-result text and image content, classify source bytes, and interpret image references |

`apps/ivenna` links the libraries into one process. Its [HTTP listener](../apps/ivenna/src/service.zig) runs alongside the kernel and shares the application's shutdown scope. `apps/memory` is a separate program reached through SSH; its handler and image sources live together, while local service orchestration remains in `dev`.

The execution core and concrete capabilities share `agent_contracts`, which depends only on Content. Content supplies tool-result text and image representation and source classification. YAML rendering belongs to the agent. The build declarations enforce the following module dependencies; each arrow points from a module to one it imports:

```mermaid
flowchart TD
    App[apps/ivenna] --> Agent[packages/agent]
    App --> Contracts[packages/agent_contracts]
    App --> Email[packages/email]
    App --> Responses[packages/responses]
    App --> Host[packages/host]
    App --> Memory[packages/memory]
    Agent --> Contracts
    Email --> Contracts
    Responses --> Contracts
    Host --> Contracts
    Memory --> Contracts
    Host --> Content[packages/content]
    Memory --> Content
    Responses --> Content
    Agent --> Content
    Contracts --> Content
    Content --> Zignal[Zignal]
    Agent --> YAML[YAML]
```

### Shared contracts

At runtime, the application supplies concrete capability implementations to the core through shared contracts. Kernel calls the input, sending, and history storage operations; Engine calls the model and registered tools. These calls dispatch to the supplied implementations, whose code runs in the same process.

The agent exposes `Kernel`, `Engine`, and its `Input` message types and renderer. Session scheduling, owned deliveries, activations, and retained context remain core implementation details. `Kernel.Config` and `Kernel.Limits` describe execution policy; `Engine.Reasoning` selects ordinary reasoning effort for core and branch roles. Connection settings and protocol encoding belong to their capability packages; the application loads environment values and owns HTTP listener settings.

Shared [communication types](../packages/agent_contracts/src/communication.zig) describe incoming observations and explicit outgoing messages. The shared capability contracts define calls and data exchanged within the process. The agent owns model-input rendering, handovers, history-record encoding, and the active-session checkpoint; each adapter owns its service protocol encoding:

| Contract | Operations | Implementation |
| --- | --- | --- |
| [Inbox](../packages/agent_contracts/src/inbox.zig) | Poll `Inbox.Incoming` messages with opaque receipts and acknowledge durable admission | Email integration |
| [Communication.Sender](../packages/agent_contracts/src/communication.zig) | Submit explicit outgoing messages using correspondent IDs | Email integration |
| [HistoryStore](../packages/agent_contracts/src/history.zig) | Load and save the current checkpoint; allocate groups, discover record metadata, read and create records in batches, and maintain the selected history | Email integration |
| [Model.Port](../packages/agent_contracts/src/model.zig) | Infer, measure the encoded request, and apply model content limits | Responses adapter |
| [Tools](../packages/agent_contracts/src/tool.zig) | Register a capability's declarations with its invocation entry point | Host and Memory |

`Communication.SendResult` distinguishes a submitted message from an unsupported recipient. The sending adapter classifies recipient support before submission; execution renders the corresponding tool result. Infrastructure failures propagate through the error channel.

The email integration uses the configured mail account for communication copies and working history. It owns native addressing, folders, markers, and record lifecycles behind the shared contracts. The [email boundary](#email-boundary) describes its storage protocols and operation ownership.

The email adapter supplies `Inbox.Incoming` with a complete `Communication.IncomingMessage` and an optional opaque receipt. [Work](../packages/agent/src/work.zig) owns the accepted event and its receipt until admission is acknowledged. The receipt stays outside model input; [activation admission](#activation-admission) defines when it can be released.

The application owns service, kernel, and shutdown tasks. The [kernel](../packages/agent/src/kernel.zig) owns intake and execution tasks within that scope. Task failures close reception and cancel and join concurrent work before shared dependencies are released. The [session registry](../packages/agent/src/sessions.zig) serializes queue and history changes; workers infer from owned snapshots and commit complete rounds before their model-round arenas end.

## Service and reception

The application initializes the mail integration, checks memory, and [restores sessions](#startup-and-interruption) before binding `SERVICE_ADDRESS` and starting kernel tasks. The kernel completes initial history maintenance before opening reception and dispatching startup activations. Readiness does not wait for their model work to finish.

While the listener is running, `GET /healthz` reports that the HTTP service is responding. `GET /readyz` returns success with `X-Ivenna-Ready: true` only while reception is open; otherwise it returns `503`. Closing is terminal for that kernel instance. The status endpoint reads this lifecycle state; it does not perform fresh dependency checks or reserve processing capacity.

The receiving boundary checks reception status before accepting correspondence. This is a precheck: shutdown can follow a successful check, and an already accepted message can remain in the account's mail storage. The receiving policy is configured in the deployment's mail infrastructure. The [running guide](running.md#service-status-and-reception) describes the reception contract and HTTP status interface; the [local mail setup](../dev/README.md#configuring-mail) provides an SMTP example.

Reception status belongs to the service boundary. Model reasoning and tools do not manage transport availability, offline queues, or sender retries.

## Sessions, work, and communication

| Concept | Role and lifetime |
| --- | --- |
| Task | Work to be accomplished; it may continue across activations |
| Core session | Permanent coordinating session with saved history and a runtime queue and execution lane |
| Work session | A fork with an independent history, queue, parent, and any children |
| Input | Message observation with `from` IDs, text, and observation time |
| Delivery | An owned event being queued or executed, with an optional input receipt until admission is acknowledged |
| Activation | One session processing a selected group of deliveries through model and tool rounds, until a final response or a fork |
| Model round | One model response followed by all tools it invoked |

Every incoming message enters the core independently, including messages a mail client groups into one thread. Receiving an observation does not imply that Ivenna was addressed or must respond. All correspondents share its FIFO queue; scheduling distinctions by correspondent ID remain undecided. Ivenna interprets each message alongside retained understanding, while Sessions owns execution histories and queues.

Core and work sessions expose `send_message`, `fork_session`, and the full shared memory interface. Work sessions also expose host tools. Engine assembles each [model request](#model-requests-and-tools) using the current session's role. `send_message` is available independently of the activation's incoming messages or result destination. For ordinary work, a response without tool calls ends the current activation: its final text is an internal result in the core or a report to a work session's direct parent. The broader task can remain open.

`MAX_PARALLEL_ATTENTION` bounds concurrent work-session execution; the core has a separate serial lane. `MAX_ATTENTION_CONTEXTS` bounds retained contexts, including the core. It also bounds each session's active and queued ordinary deliveries plus reserved child reports. Startup adds one control observation per session outside that ordinary delivery budget. Input that cannot be admitted stays with its producer; the mail integration leaves it available for later polling. Idle parents retain context while their children work without consuming a work slot. The core still processes its requests serially, so responsiveness also depends on short coordination turns and service latency.

A work activation reserves space for its report in its direct parent's admission budget. The initial reservation is made when preparing a fork; a later activation, including a fresh startup activation, reserves a new slot before it starts and waits if the parent has no capacity. A completed report consumes that slot and joins the parent's queue, so later input cannot take its place. Runtime `queued_inputs` counts actual queued deliveries, excluding these reservations.

## Activation admission

When a session is ready, Sessions claims the events already in its queue. The kernel selects the longest nonempty FIFO prefix that fits the complete ordinary request, including retained history, the record for the new event group, current state, and tool definitions. Selection starts from the available queue without waiting for more arrivals. The selected group enters retained history as one record and shares one inference. Events arriving during admission or later tool rounds stay queued for a later activation.

When old working history prevents even the first event from fitting, the kernel summarizes that history and selects again. That summary does not process the new events. If the first event cannot fit after compaction, or there is no earlier work to compact, admission fails with `ContextBudgetExhausted`. Events excluded by the budget return to the queue's front, before arrivals received during selection, preserving FIFO order.

Before the activation's first ordinary model or tool round, the kernel saves the selected input record and confirms its checkpoint, then calls `Inbox.acknowledge` for each selected receipt. Each successful acknowledgement releases that delivery's receipt and changes its notice to acknowledged. An excluded event keeps its receipt and remains pending. Acknowledgement transfers responsibility for the input to retained history; it does not certify task success. Acknowledged notices remain until a later poll no longer returns those messages.

## Forks and work ownership

`fork_session` accepts a `task` and passes the whole activation's work to one new work session. A model round can create at most one fork. The [tool definitions](../packages/agent/src/tools.json) own its parameters.

Sessions reserves child identity, context capacity, and parent report space during tool invocation. It publishes the fork only after committing model output and one result for every tool call, so inherited history contains a complete exchange.

A fork copies the caller's complete retained context, including any compaction handover. It receives an assignment, and its model request supplies its current state. Histories then grow independently while the host, memory, and world effects remain shared. The [input contract](input.md#assignments-and-reports) defines assignment and report fields.

Publishing a fork ends the caller's activation. The child handles its assignment in a new activation, using the complete inherited history. Queued deliveries remain with the caller, which returns to its own queue without another inference to conclude the transfer. Later messages still arrive at the core.

A work session's final text returns one combined result for that activation to the session that created it. The report enters the tail of that parent's FIFO queue and can join other events in a later activation. It does not modify history during an ongoing model round. Nested forks return through their direct parents; a child does not inherit an ancestor's reporting destination. Internal assignments and reports have no input receipts.

Session identifiers and parent relationships persist with retained contexts. The [startup contract](#startup-and-interruption) describes how those relationships and unread internal work are restored.

## Activation completion and context release

Engine completes each tool batch with one result per call. Sessions copies accepted model output, including reasoning items, and tool results into retained history before the model-round arena ends. A published fork ends the caller's activation; otherwise, tool results feed another round. Intermediate assistant text and complete exchanges remain in history.

An ordinary final response without tool calls completes the selected group. This ends execution of that activation, without certifying that the broader task succeeded. A work session's combined final text, including empty text, is copied into one report delivery for its direct parent. Core final text remains internal. Sending occurs only when a `send_message` tool call executes, so an activation can submit several messages or none.

Sessions releases a work context when it has no active or queued deliveries, children, or worker borrows. Children retain an idle parent without occupying a work slot; a worker's borrow keeps its session alive until the worker returns. A queued report owns its text independently of the child's context and model-round arena. Its `from_session` identifies the source without retaining that source's full working history. Releasing the context removes the session from subsequent checkpoints, so it is no longer scheduled or restored at startup.

The permanent core stays available between activations. Its context is summarized when it needs compaction.

## Records, context, and current requests

[Input](../packages/agent/src/input.zig) defines and renders retained `Record` messages and temporary `Request` messages. Records contain admitted events or a compaction handover; requests supply current state and instructions. Communication observations use `Event.input`, and startup uses `Event.startup`. Event grouping, assignments, reports, and execution state belong to the core. The [input contract](input.md) owns their serialized payload and field reference; the [system prompt](../packages/agent/src/system.md) explains their meaning to the model.

Sessions fixes the selected delivery group, returns the unselected suffix, and installs the selected history under the registry lock. [Context](../packages/agent/src/context.zig) owns typed admitted event groups, complete model/tool exchanges, and handovers. Model exchanges retain native `Model.Item` values, including opaque adapter continuation bytes and typed tool results. Continuations preserve complete model output, including reasoning, in the producing adapter's format. The agent copies and persists those bytes without interpreting them; they remain specific to the producing adapter. Forks inherit the same earlier history entries with their original receiving session identifiers.

Context derives and caches native model messages from the current system prompt, rendered event groups and handovers, and stored model/tool exchanges when restoring or changing its source entries. For each inference, the kernel takes an owned history snapshot and obtains current state from Sessions. `Context.request` appends one temporary request to that cached model-message view without changing the snapshot. The kernel keeps the snapshot alive until the model/tool round returns. Request state and summary instructions stay outside retained history; later rounds use that history or its replacement handover.

Appending history clones and renders only the new entry, with amortized growth of the entry and message arrays. Forks and inference snapshots still copy their retained contents for independent ownership. Admission candidates borrow the snapshot's model messages and render only the proposed event group and current request; the selected context is copied once after measurement.

## Model requests and tools

The rendered `Input.Request` is the final YAML user message in a model call. For ordinary inference, [Engine](../packages/agent/src/engine.zig) combines that message and retained history with selected tool declarations and explicit reasoning effort to form a [Model.Request](../packages/agent_contracts/src/model.zig).

Tool declarations live with their owning implementations: [communication and session tools](../packages/agent/src/tools.json), [host tools](../packages/host/src/tools.json), and [memory tools](../packages/memory/src/tools.json). Host and Memory register their declarations through `Tools`. The application supplies Memory through `Engine.shared_tools` and Host through `Engine.work_tools`. Engine includes its own declarations and shared tools for both roles, adding work tools for branches. Invocation uses the same role selection.

Engine selects ordinary reasoning effort from `Engine.Reasoning` using the current `Input.Role`: core defaults to `low`, branch to `high`. All sessions use the same configured model and output-token limit through a shared provider. The [Responses adapter](../packages/responses/src/provider.zig) encodes the selected declarations and reasoning effort in the service protocol, including `reasoning.effort`. Byte measurement uses the same payload encoder as inference, including while applying tool-result limits.

The Responses adapter decodes the entire output batch before Engine executes any tool in it. It validates the fields needed to extract calls and assistant text, and retains each output item as opaque continuation data. Execution and compaction use those decoded values. An incomplete response fails model execution before any of its tool calls execute. In ordinary work, unknown tools and invalid arguments become tool errors available to the next model round.

### Tool results

[Content](../packages/content/src/root.zig) owns native text and image parts, encoded image metadata in [image.zig](../packages/content/src/image.zig), and classification of individual byte sources. The owning tool renders unavailable-content diagnostics as text. Classification borrows bytes; a separate explicit interpretation can present source text as an image reference. Pixel decoding and URL retrieval belong to the model service.

Memory and Host return content in the model-round arena. Engine creates a native tool result with its call ID and content; the Responses adapter encodes it for the configured model service. Local image bytes become request data; remote URLs remain references whose contents can change. Image rejection preserves accompanying text and reports the omitted image. Image limits apply once to the complete tool batch alongside the whole-context budget. See [tool content](content.md) for formats and limits.

## Bounded model context

`CONTEXT_REQUEST_BYTES` bounds the complete ordinary [model request](#model-requests-and-tools), including system instructions, retained records and exchanges, current state, tools, reasoning settings, and encoded images. `LLM_MAX_OUTPUT_TOKENS` separately bounds generated output, including reasoning tokens.

After admission, each tool continuation checks the complete request budget again and can compact the activation's retained history when needed.

Compaction presents retained history followed by a temporary `Input.Request` with response `summary` and instructions from [compaction.md](../packages/agent/src/compaction.md). Its `Model.Request` has no tools and uses `high` reasoning effort, independently of the ordinary session settings. The Responses adapter encodes the absence of tools as `tool_choice: none`. `CONTEXT_COMPACTION_BYTES` bounds that complete request; `HANDOVER_MAX_BYTES` bounds its nonempty text result.

The kernel builds the replacement's ordinary request with a fresh state snapshot and checks its complete budget before installing the handover record. Compaction starts a new active working history from that handover, preserving the session identity and parent relationships. It replaces the entire earlier working view, including its raw transcript tail. Retention of earlier history records is a separate storage lifecycle. Summary instructions preserve relevant session and correspondent IDs, relationships, ongoing work, commitments, and completed effects.

Byte counts are local measurements, not model-token estimates. If a request or summary cannot meet its bound, execution fails explicitly rather than cutting an unfinished exchange.

FIFO admission still measures successive event prefixes through whole-request encoding. With `Q` candidate prefixes and a largest encoded request of `B` bytes, this can take `O(Q * B)` work. Trial allocations are reused between candidates, so they occupy space for one candidate rather than all prefixes. The model contract exposes whole-request measurement.

## Persistent working history

The agent's [history codec](../packages/agent/src/history.zig) stores immutable records and a current checkpoint selecting the working histories for continuation. A session's history consists of ordered prefixes of history segments. Forks inherit those prefixes and append in the child's own segment. Compaction begins a replacement segment with a handover while preserving the session's identity and parent relationships.

| Term | Meaning |
| --- | --- |
| Session | A core or work session with its own identity and parent relationship |
| Segment | An append-only sequence identified by `Scope { session_id, epoch }`; a fork starts its own segment, and compaction advances its session's epoch |
| Storage group | An opaque identifier used by `HistoryStore` to discover a segment's records |
| Span | A checkpoint's selected prefix of a segment, identified by its group, head key, and entry count |

Each entry retains its segment identity and either a complete admitted `Input.Record` or a complete model-output and tool-result batch as `Model.Item[]`. Inherited event groups keep their original receiving session identifier and event order. Exchanges preserve opaque model output, including reasoning, and typed tool replies with text and media. Local image bytes remain in the records; remote images retain their URLs. Inference snapshots copy segment identities along with entries.

Records use compact UTF-8 ZON bodies. An entry record contains the entry and its predecessor's SHA-256 key within that segment, or null for the first entry. Its own key is the SHA-256 of the complete encoded body. Segment identity and predecessor keys distinguish occurrences even when their payloads are equal. Unread internal assignments and reports are stored together in a separate immutable observation-array record in the session's current group.

The checkpoint contains the next session identifier and each retained session's identity, parent relationship, epoch, current group, and ordered spans. An optional key selects the unread observation array in the current group; its text stays outside the checkpoint. Appending advances a span's head and count without adding a per-entry reference. The latest confirmed checkpoint selects both the contexts restored at startup and the records kept by [history maintenance](#history-retention).

### Saving and restoration

`HistoryStore` provides grouped record operations, checkpoint loading and publication, and maintenance against a retention selection. The agent's codec owns segment identity, record encoding, content keys, committed paths, and retention selection, and validates the checkpoint and selected history. The adapter owns native group representation, locators, placement, and request limits. It decodes reference metadata and returns one complete body per requested reference in input order. Native locators do not appear in the checkpoint.

The runtime saves after activation admission, accepted complete model/tool batches, compaction, fork publication, and context release. A save encodes and hashes records to compare each segment against its cached prefix, then creates new occurrences and changed unread-observation records in batches. Each batch holds up to 32 records and about 1 MiB of encoded bodies, allowing a single larger record. All required creates must be confirmed before publishing the checkpoint. An interrupted or unconfirmed create can leave records outside the selected paths; neither exactly-once creation nor archive-wide deduplication is guaranteed.

Checkpoint sessions serialize in ascending ID order. If the encoded checkpoint matches the last successfully loaded or saved checkpoint, the codec skips publication. A publication error may occur after the new checkpoint has reached storage, so it invalidates that comparison digest while retaining the confirmed record cache. The [email integration](#history-storage) owns publication and current-checkpoint selection in the mail account.

Restoration discovers metadata for every group named by the checkpoint. The codec follows predecessor keys in memory from each committed head, checks its count, and selects the required records before reading their bodies in batches. It verifies body hashes, predecessor metadata, segment identity, and record kind, then decodes each selected record once to assemble retained contexts. Duplicate physical records with the same key and matching predecessor metadata can supply one logical occurrence; the selected body's hash is still checked. Missing or inconsistent committed records fail restoration. Records outside the selected paths remain uncommitted or historical material.

Delivery and activation objects, input receipts, worker ownership, and host process handles are outside the checkpoint. The [startup contract](#startup-and-interruption) describes reconstruction and interruption semantics. Storage and decoding failures end startup or execution rather than silently starting with empty history. History search and model tools for retrieving earlier records are unimplemented.

### History retention

A retained session appends to its current segment. Compaction seals that segment and starts another; forks can continue to reference a sealed segment's inherited prefix. Releasing a context removes its session from the next checkpoint, while records shared with another retained context remain selected. Earlier checkpoints are not restoration roots.

The intake loop runs maintenance before opening reception. After that, it checks between polls whether at least 60 seconds have elapsed since the previous maintenance pass. The registry holds its lock while saving the current contexts and reconciling storage, so maintenance uses a confirmed checkpoint and cannot overlap record creation or publication.

The codec derives `HistoryStore.Retention` from the last successfully loaded or saved checkpoint. `active_groups` names each retained session's current writable group. `records` names every selected `(group, key)`, including inherited prefixes and unread internal observations. The adapter uses this complete selection to place records and retire unselected material, without interpreting session identities or checkpoint bodies. Unchanged saves can skip checkpoint publication while still allowing maintenance.

The [email integration](#mail-retention) maps writable, sealed, and unselected records to its history, archive, and Trash folders. The mail service controls how long retired objects remain in Trash and when their storage is reclaimed.

### Processing cost

With expected hash-map lookup costs, local save work follows the entry bytes referenced across retained sessions plus checkpoint metadata, with an additional sort of the bounded retained-session list. Snapshot comparison still encodes and hashes retained entries, including shared inherited prefixes; unchanged saves skip native publication rather than this local work. Temporary record encoding space holds a bounded batch plus the largest record. The in-memory group and key cache covers the last confirmed checkpoint.

Checkpoint size follows retained sessions and their segment spans rather than accumulated model rounds. A fork adds a segment while reusing its inherited spans; compaction replaces a session's spans with its new handover segment.

Group discovery can return metadata for uncommitted records and for a parent's later suffix beyond a child's inherited prefix. The codec reads bodies only for the selected committed records. All group identities are available before retrieval, so predecessor traversal needs no storage request per link. Native filtering and pagination costs depend on the backend and accumulated records; the [email storage section](#history-storage) describes the current access path.

## Startup and interruption

Startup discovers the mail account and checks memory through a read-only `inspect_memory_space` exchange. Both must succeed before the kernel starts. Memory is required throughout operation.

The kernel loads the current checkpoint and its committed records through `HistoryStore`. If no history exists, it creates the core. It rebuilds session identities, parent relationships, and working contexts with the current system prompt.

Each retained session queues a `startup` observation before its unread internal assignments and reports. Normal FIFO request-budget admission selects events for fresh activations, which can include startup and unread work together. A work activation reserves report space in its direct parent before it starts. Startup work can run without incoming mail; a newly forked session begins with an assignment instead. Before reception opens, the mail integration has retired leftover communication copies and the kernel has run [history maintenance](#history-retention).

Startup creates fresh execution state without restoring prior activations, external input deliveries, receipts, or processes. Restored parent relationships route future reports to the direct parent. Current request state is authoritative about the new runtime; retained records describe earlier observations. Ivenna chooses how to continue from that evidence. Ordinary unacknowledged mail remains eligible for intake. A crash between history publication and acknowledgement can leave a message eligible even when its observation already survives in history. Correspondent IDs retain their destinations within the configured domain.

A host command, memory change, or submission may have taken effect before its complete model/tool batch was saved. Losing a submission response can leave acceptance unknown; repeating it can produce a duplicate. The runtime does not replay historical calls or guarantee exactly-once effects. Uncertain effects may need inspection before further action. Automatic retry and reconnection remain undefined.

The runtime assumes one kernel per Ivenna account. Message submission, input acknowledgement, host effects, memory writes, and history storage do not share a transaction.

Infrastructure failures in communication and memory, along with model execution, compaction, and history storage or maintenance errors, propagate through the kernel's tasks. A task error ends the kernel and its task scope. Defined tool outcomes, including invalid arguments, command failures, and memory-handler domain errors, remain results for the model to interpret.

## Email boundary

[Addressing](../packages/email/src/addressing.zig) derives the correspondent domain from `MAIL_ADDRESS`. It projects a same-domain address's local part into a readable ID and resolves an outgoing ID back into that domain. Domain comparisons ignore case; IDs preserve case. The supported ASCII ID and domain forms are described in [communication](communication.md#current-email-addressing) and [mail setup](running.md#mail-service).

[EmailTransport](../packages/email/src/email_transport.zig) projects received From addresses into the correspondent ID strings in `IncomingMessage.from`. It renders a nonempty subject, a blank line, and the body as complete received text; with an empty subject it uses the body alone. The observation also records the runtime's observation time. Received mail must have at least one From address, and every address must map to a supported same-domain ID.

Messages whose From addresses cannot map to supported correspondent IDs are excluded from intake. The mail client continues through native query pages to fill the requested result limit, so excluded records do not hide later eligible messages. Filtering leaves the original copies unchanged.

Each send resolves recipient IDs in the configured domain and submits a standalone email with subject `Ivenna` and the supplied text as its body. Unsupported IDs return the ordinary `invalid_recipient` tool result. IDs retain their destinations across context release and restart with the same domain configuration. Native addresses, delivery records, headers, folders, and private markers remain within the email integration.

The adapter creates each outgoing copy in Drafts with `ivenna-outbound`. Confirmed submission uses `onSuccessUpdateEmail` to remove draft state and move the copy to Trash. Both submission and that implicit update must be confirmed before the adapter returns its opaque submission reference. Under [RFC 8621 §7.5](https://www.rfc-editor.org/rfc/rfc8621.html#section-7.5), retiring the Email after successful submission does not cancel delivery. Service acceptance does not establish final recipient delivery.

The boundary prefers decoded plain text and falls back to UTF-8 HTML source. Unsupported or incomplete bodies produce a diagnostic and are skipped without changing the original copies. Supported text enters the message in full and is subject to [whole-request admission](#activation-admission). Intake uses polling; mail attachment intake is unimplemented.

### History storage

The email integration creates history records and checkpoints as JMAP Email objects in the top-level `Ivenna History` folder through `Email/set`. Selected records from sealed segments move to the top-level `Ivenna Archive` folder. The adapter discovers both folders by name, a null `parentId`, and a null `role`, and creates them when missing. It also discovers or creates the mailbox with role `trash`. Each object has a plain-text ZON body carrying the agent's encoding and a self-addressed envelope supplying native identity metadata. Creating these records does not submit correspondence.

All history objects carry the private `ivenna-state` keyword and an `X-Ivenna-History-Kind` header of `record` or `checkpoint`. The adapter allocates a fresh opaque group token and maps it to an exact keyword of the form `ivenna-history-<token>`. Records carry that group keyword, their `X-Ivenna-History-Key`, and an optional `X-Ivenna-History-Previous`. These headers expose record keys and predecessor metadata for retrieval; searches use native keyword membership rather than header or full-text indexing.

To discover records, the adapter queries `Ivenna History` and `Ivenna Archive` with the state marker and requested group keywords. It fetches record metadata in bulk, validates ownership and group membership, and returns opaque native locators to the agent. After the codec selects committed paths, the adapter reads those locators through bulk `Email/get`, validating group, key, predecessor, self-addressed identity, and complete text bodies. Trash is outside continuation reads. The agent then verifies hashes and decodes payloads. Native `Email.id` values serve as transient locators, not checkpoint identities.

Record creation uses bulk `Email/set` and confirms every requested create before returning success. Get and set batches obey the JMAP session's positive `maxObjectsInGet`, `maxObjectsInSet`, and `maxSizeRequest` limits, with at most 32 objects per batch. Native request sizes include encoded bodies and protocol fields. Group discovery requests pages of up to 512 IDs independently of get limits, then splits metadata and body reads into bounded native batches.

In the supplied Stalwart 1.0.2, [folder and keyword matching](https://github.com/stalwartlabs/stalwart/blob/v1.0.2/crates/email/src/cache/email.rs) can scan the account's message cache. Grouping limits which metadata and bodies reach the agent; it does not guarantee lookup work proportional only to the selected history.

Current checkpoint candidates carry both `ivenna-state` and `ivenna-current` and a numeric `X-Ivenna-History-Revision`. Discovery queries `Ivenna History` and those keywords, then validates returned metadata. Malformed kind or revision metadata on an owned current candidate fails loading. Loading selects the highest revision, independently of mail observation timestamps. Distinct candidates at the same highest revision are an error. Saving confirms creation of the complete new checkpoint; maintenance later removes the current marker from older checkpoints and moves them to Trash. Several candidates can remain between maintenance passes or after interruption, and the numeric revision identifies the current checkpoint.

A failed batch returns an error even when some objects may already have been created. Native group membership identifies candidate records; the checkpoint's committed heads and predecessor keys select the effective history. Mail threads describe correspondence and do not supply Ivenna's segment, fork, or compaction relationships.

### Mail intake and acknowledgement

The [email integration](../packages/email/src/root.zig) polls through the [mail client](../packages/email/src/mail.zig) for physical input messages without the private `ivenna-handled` acknowledgement keyword. Intake spans correspondence folders and is independent of read and starred state. The `Ivenna History`, `Ivenna Archive`, Drafts, Junk, and Trash folders are excluded, along with drafts and messages carrying `ivenna-outbound` or `ivenna-state`. The state marker keeps history records out of intake even if they are moved from those folders. The runtime marks its outgoing messages with `ivenna-outbound`; correspondents send from separate accounts.

Acknowledgement sets `ivenna-handled` and moves the input copy to Trash after the kernel confirms durable admission. Read and answered state are unchanged. The marker describes transfer into retained history, independently of the task's remaining work. Sessions keeps receipt bookkeeping only in memory.

### Mail retention

Communication copies and history records retire into Trash. The mail service owns expiry and storage reclamation under deployment policy, independently of whether Ivenna is running. The [running guide](running.md#data-and-retention) describes retention and preservation requirements.

#### Communication copies

The kernel's acknowledgement retires an input copy after durable admission. The sending operation retires its outgoing copy after confirmed submission. During initialization and before each poll, the email integration also retires acknowledged inputs and outgoing copies left by interrupted sends. It identifies outgoing copies by the runtime's marker and sender identity. These copies retire once no sending operation holds them, even if submission acceptance is unknown. Maintenance does not resubmit messages.

The integration holds its own lock through sending, intake, acknowledgement, and communication maintenance, so a draft needed by an in-progress send remains live. Pending input stays available for admission. Existing Trash is excluded from communication maintenance.

#### Working history

The email adapter maps the codec's [retention selection](#history-retention) to native folder membership. It inventories state objects in `Ivenna History` and `Ivenna Archive` before moving any of them. Ownership requires the runtime's state marker and self-addressed identity metadata. Owned objects must belong to exactly one folder. Maintenance uses bounded requests and classifies each physical object as follows:

| Object | Location and use |
| --- | --- |
| Latest checkpoint, or selected record in a current writable group | `Ivenna History`; current groups can receive new records |
| Selected record in a sealed group | `Ivenna Archive`; it remains available for inherited context and restoration |
| Unselected record or older checkpoint | Trash; further retention belongs to the mail service |

The adapter retains every physical copy matching a selected `(group, key)`. Unselected records include obsolete observation arrays and uncommitted writes outside the selected paths. They may move directly from `Ivenna History` to Trash. An archived record moves to Trash when it loses its last continuation reference; Archive has no age or capacity policy. The folders organize records by their use in continuation, rather than collecting a complete transcript for each ended session. Record bodies retain session and epoch identities for manual inspection.

Missing selected records, selected records from current writable groups found in Archive, and invalid metadata on owned objects are storage errors detected before folder updates. Trash is excluded from both inventory and continuation reads.

Restoration requires the latest checkpoint and all committed records with their bodies, group membership, keys, and validation metadata intact.

## Autonomous memory

Memory is a file workspace shared by all sessions. The Memory component resolves host write sources and exchanges typed JSON operations over SSH with the fixed [memory.nu](../apps/memory/src/memory.nu) handler. The handler owns file operations and capacity enforcement. See [memory rooms](memory.md) for tool behavior and [memory service requirements](running.md#memory-service) for deployment.

The handler returns explicitly defined operation errors, such as a missing entry or exhausted capacity, to the model as tool results. SSH failures, invalid protocol replies, and unclassified handler or backend failures propagate to the kernel. Finer error distinctions remain undefined.

The [memory shell](../apps/memory/memory-shell.sh) locks the workspace for each handler invocation, including capacity checks and writes. Separate operations can observe changes made by another session. Direct filesystem changes can bypass this boundary.

Transfers buffer complete files and payloads. Memory copies or decodes returned content into the caller's model-round arena before temporary SSH buffers are released. An incomplete exchange can leave the outcome of a write uncertain.

## Host execution

Work sessions execute as the kernel's OS account and share its filesystem and startup environment. Forking a model context leaves these resources shared, so a prior observation may need to be checked again after another session acts.

Host validates and routes requests. [Shell](../packages/host/src/shell.zig) executes a fresh noninteractive `/bin/sh` command; [process.zig](../packages/host/src/process.zig) owns process groups, timeouts, cancellation, and reaping. Complete output remains in host files, while [Reader](../packages/host/src/reader.zig) selects the content returned to the model.

Host propagates cancellation and allocation failure. Other invocation failures currently return `host_unavailable`, including failure to obtain a command result. Finer classification of these failures remains undefined.

The shell entry reports capabilities that remain planned alongside command execution. Their operations are unimplemented. See [host shell](host.md) for available tools, output, and interruption behavior.

## Implementation references

These references inform context, scheduling, and handoff mechanisms within Ivenna's [design intent](design.md).

[OpenAI Agents SDK handoffs](https://developers.openai.com/api/docs/guides/agents/orchestration#use-handoffs-for-delegated-ownership) provide a reference for transferring responsibility. [Codex thread forks](https://learn.chatgpt.com/docs/app-server#start-or-resume-a-thread) provide a reference for continuing stored history in a separate context. Ivenna uses context inheritance and explicit work ownership within one body.

[pi's sessions and context](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/sessions.md) distinguish stored history from the active branch supplied to a model request. Its [agent interface](https://github.com/earendil-works/pi/blob/main/packages/agent/README.md) provides a reference for queued follow-up input.
