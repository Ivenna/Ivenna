# Development

The [design intent](design.md) guides product and interface decisions; the [architecture guide](architecture.md) explains implementation responsibilities and ownership. Follow the [running guide](running.md) for deployment and configuration.

## Development conventions

The project is exploratory. Data structures, interfaces, and module boundaries are not yet settled; change them directly to match the design.

Leave behavior that needs further design as an unavailable or explicitly limited placeholder. Describe what works and what remains undecided. When a design changes, remove superseded behavior and state; do not retain compatibility paths or introduce migration frameworks.

Communication and memory are operating requirements of the whole runtime. Component boundaries organize responsibilities within that contract. Keep safeguards at the boundary that owns the requirement, use the guarantees established there, and remove duplicated checks in downstream components.

During development, do not write tests in advance or introduce test frameworks. Use the [local development environment](../dev/README.md) to run the kernel on the host and middleware in containers.

## Design and implementation

Start with the intended behavior and its reason, then establish responsibilities and interfaces. Explain design changes through their effects on Ivenna, its correspondents, or the deployment user. Implementation experience can inform these choices; a current code path or service limitation alone does not establish a design requirement.

Keep each document focused on its role:

| Document | Scope |
| --- | --- |
| Design guide | Goals, behavioral choices, interface principles, and their reasons |
| Development guide | Change conventions, implementation boundaries, builds, and validation |
| Interface guides | Operations, fields, formats, and outcomes |
| Model-facing resources | Semantics needed to choose actions and interpret observations |
| Architecture guide | The current implementation's package ownership, dependencies, algorithms, synchronization, storage representation, and service protocols |
| Running and local development guides | Deployment configuration and service procedures |

Keep project guidance focused on Ivenna's interfaces, integration choices, and their operational effects. Refer readers to component documentation for general use and administration, keeping Ivenna-specific settings and procedures here.

Design can name an operation or concept when it expresses a behavioral choice, such as explicit sending or work ownership. When behavior changes, update the affected design, interface contracts, model-facing resources, and implementation together. When replacing a mechanism while preserving behavior, update its implementation and architecture description. Describe any remaining implementation limitation and its effect in the relevant interface or operational guide.

## Implementation boundaries

### Packages and dependencies

Organize packages around cohesive capabilities, keeping their types, rules, resources, and implementation together. Public interfaces should let callers use a capability without coordinating its internal components. Keep supporting mechanisms with their owning capability. Applications select implementations, load deployment settings, and own program startup and shutdown.

Use `packages/agent_contracts` for shared communication and capability contracts. Keep execution policy, model-input types and rendering, prompts, and runtime tool declarations in `packages/agent`. Follow the [architecture guide's responsibilities and dependency graph](architecture.md#responsibilities), and update producers and consumers together when changing a shared type or operation.

Keep configuration with the behavior it controls. Execution owns scheduling, context limits, and reasoning selection; capability packages own connection settings and protocol encoding. The application translates environment values into those configurations and owns HTTP listener settings.

### Types and protocols

Decode external protocols in their owning components and give execution code typed operations. Callers rely on the guarantees established by language types and supplying components within their documented scope and lifecycle. Validate additional requirements at the boundary that owns them.

Work, session scheduling, and model observations must not depend on mail records, headers, folders, or native thread identifiers.

Model coexisting fields together and mutually exclusive alternatives as distinct variants in language types and structured data. Keep variant-specific fields tied to their discriminator.

Construct typed [Communication](../packages/agent_contracts/src/communication.zig) messages and [Inbox](../packages/agent_contracts/src/inbox.zig) correspondence or callback envelopes at their producing boundary. The email adapter owns the internal domain, address conversion, callback mailbox records, and [message projection](architecture.md#email-boundary). The agent owns callback registration, source classification, destination selection, and duplicate admission.

Observations carry complete text strings; tool results use [Content](../packages/content/src/root.zig) parts. Keep [model messages and tool results](../packages/agent_contracts/src/model.zig) typed. Preserve model output as opaque continuation bytes owned by the producing adapter's format; execution copies and retains them without reading protocol fields.

Keep input rendering separate from provider encoding: [Input](../packages/agent/src/input.zig) renders retained event and handover records and a per-inference turn whose current state accompanies one work or summarization purpose. Model output and tool replies keep their own roles and formats. The agent selects tools and reasoning effort for each model request; the adapter encodes and measures the complete request with those settings, including while applying tool-result limits. Use the same encoder for measurement and inference, and pass settings per request without mutating a shared provider.

### Model-facing resources

Treat prompts and tool descriptions as editable interfaces:

| Resource | Purpose |
| --- | --- |
| [system.md](../packages/agent/src/system.md) | Input interpretation and response scope needed by the model |
| [Agent tools](../packages/agent/src/tools.json) | Correspondence, session coordination, forks, and wakeups |
| [Host tools](../packages/host/src/tools.json) | Host shell actions, invocation parameters, and results |
| [Memory tools](../packages/memory/src/tools.json) | Memory actions, invocation parameters, and results |
| [compaction.md](../packages/agent/src/compaction.md) | What a handover must preserve |

Keep tool names, descriptions, and parameter schemas with their owning implementation. Capability providers register their declarations through `Tools`. Keep tool availability policy in the agent and use the same role selection for declarations and invocation. Model adapters add protocol-specific declaration fields when encoding the selected tools. The [architecture guide](architecture.md#model-requests-and-tools) describes the current assembly and selection.

Put task facts and observations in user input. Include runtime rules in these resources when they affect a model decision or the meaning of input, actions, or results. Keep descriptions concise, with detailed field references in the [input contract](input.md), scheduling and storage mechanisms in the architecture guide, and service procedures in the running guides. Update the owning resource, implementation, and interface documentation together when a contract changes.

Keep outgoing messages, internal reports, callback observations, handovers, and diagnostics distinct. Outgoing communication occurs through `send_message`. For ordinary work, a final response ends the activation only when no pending events or core attention signal require another inference; completion supplies an internal core result or branch reports to the direct parent and core. Summary text supplies a handover for continued execution, without responding to retained events. Preserve text, media, and source descriptions together when handling [tool content](content.md).

### Session execution

Keep context, queue, activation, and callback-registration changes under the session registry's synchronization; the kernel coordinates adapter operations and worker task scopes. Copy or transfer values that must outlive a model-round arena. Admit new event groups only between complete model/tool batches and the next inference. Give eligible work sessions fair opportunities to start activations while preserving the core's independent lane; this does not require preempting running rounds. Follow the architecture contract for [activation completion and sleep](architecture.md#activation-completion-and-sleep).

Keep attention scheduling separate from durable observations. Changes in work sessions can schedule the core without adding an event. Consume that signal only when submitting an ordinary inference; budget measurement and summarization leave it pending.

Keep session identity independent of context residency. Unload only confirmed history whose spans remain selected in the checkpoint, and restore it when the session receives work. Event sources bind to their destination when created; a fork does not retarget existing sources. Keep registered-session, pending-event, pending-callback, background-command, and execution-concurrency limits separate. Callback mail remains pending when its destination queue is full.

Keep callback registrars scoped to one invocation. Host can retain the registered ID and publish terminal text through `Callback.Publisher`; it cannot retain a registration context or select another session. The agent owns registration and durable admission, and the adapter owns [callback storage](architecture.md#callback-delivery). Keep that internal path independent of correspondence reception, with separate intake allowances so correspondence backpressure cannot consume the callback allowance.

Background host tasks belong to the application's runtime scope and can outlive a session activation. Shutdown cancels and joins those tasks before releasing their publisher and dependencies. Callback mail can survive restart; host process handles cannot. Restore unfinished registrations as unknown interrupted outcomes rather than rerunning their commands.

Infrastructure and execution failures propagate to the application's task scope, which closes reception, cancels, and joins all work before shared dependencies are released. Ordinary tool outcomes remain model observations.

The application serves health and reception status. The mail server's receiving boundary uses that status before accepting incoming SMTP correspondence. Keep this gate separate from model reasoning and in-process work queues; its readiness check does not reserve an activation or establish an atomic delivery transaction.

### Working history

Retain typed event groups, complete model/tool exchanges, and handovers in Context. Assemble each inference with a turn containing `current` and a tagged `purpose`. Ordinary assembly combines new observations with the full current-state snapshot, without duplicating their history record in that request's prefix. If compaction occurs first, the retained observations can instead be carried by the handover. Retain observations without transient state; preceding messages, handovers, and autonomous memory carry task understanding. The [architecture guide](architecture.md#working-history-and-user-messages) describes assembly and ownership.

Measure admission candidates with the state their admission would produce, including excluded events returning to the queue and selected callback registrations being removed. Keep each candidate's projection independent of the registry and other candidates so budget checks use the same request assembly as execution.

Generate a handover from retained LLM messages plus a turn with `purpose.summarize` and fresh current state. This maintenance inference admits no queued events. Replace the old message sequence only after the handover passes validation, then use the system prompt, handover, and a new ordinary turn for continuation.

Persist all registered sessions, preserving complete model/tool exchanges, unread internal observations, pending callback IDs and destinations, wakeup deadlines, and confirmed spans for unloaded contexts. Assignments, reports, and handovers retain the understanding of work. Confirm each admitted group and its checkpoint before [acknowledging its receipts](architecture.md#mail-intake-and-acknowledgement). For callbacks, persist the observation and registration removal together, maintaining the [duplicate barrier](architecture.md#event-sources-and-callback-admission) until admission is confirmed. Acknowledgement releases transport copies independently of task completion.

Follow the [startup contract](architecture.md#startup-and-interruption) when restoring sessions. Execution ownership, input delivery objects, receipts, and process handles belong to the running process; loading history must not execute historical tool calls. Storage failures end the runtime through the normal execution failure path.

Keep history encoding, segment identity, committed paths, and retention selection with the agent. Use `HistoryStore` for grouped records, checkpoint publication, and maintenance against that selection. Adapters own native identifiers, placement, protocol limits, and result correlation; storage services own expiry and space reclamation under deployment policy. Keep communication-copy retirement, working-history retention, and host-artifact lifecycles with their owning components.

Confirm records before checkpoint publication. Serialize writes and maintenance through the session registry, and reconcile storage against a confirmed checkpoint before retiring records. Complete native inventory and selection checks before moving objects. The architecture guide defines [history representation and save boundaries](architecture.md#persistent-working-history), [retention selection](architecture.md#history-retention), and the [email storage lifecycle](architecture.md#mail-retention).

## Repository and build

| Location | Responsibility |
| --- | --- |
| [apps/ivenna](../apps/ivenna) | Configuration, adapter assembly, HTTP status, application startup and shutdown |
| [apps/memory](../apps/memory) | Remote memory handler, image, and SSH entry point |
| [packages](../packages) | Runtime libraries and their resources; see the [architecture map](architecture.md#responsibilities) for each package's interface and responsibility |
| [dev](../dev/README.md) | Local service orchestration, mail provisioning, and memory SSH preparation |

Each Zig library declares its module and dependencies in `build.zig` and `build.zig.zon`, with public exports in `src/root.zig`. When adding or moving a unit, update its consuming build declarations, the [root package's exported source paths](../build.zig.zon), and the architecture map. `apps/ivenna` links the libraries into one executable. The memory app is a separate Nushell program; its Containerfile packages it for container use.

Install the Zig version in [`.zig-version`](../.zig-version), then build the application from the repository root:

```sh
zig build
```

The executable is installed at `zig-out/bin/ivenna` and embeds the [model-facing resources](#model-facing-resources). Rebuild it after editing code or those resources. The [local development guide](../dev/README.md) covers service preparation, running from source, and updating middleware; the [running guide](running.md#starting-the-kernel) covers starting the built executable.

## Validation

Build the application and exercise the affected behavior through communication and model/tool work:

| Area changed | Checks |
| --- | --- |
| Execution | Joint processing of queued events, budget-limited FIFO admission before later inferences, durable acknowledgement of each admitted prefix, complete tool batches, fair activation dispatch among eligible work sessions, forks and nested creation notices, direct session messages, parent/core reports and capacity checks, attention-only core activations, sleeping-session callbacks, and context unload/restore |
| Failure handling | Required-capability failures stop the runtime and join concurrent work; ordinary tool outcomes allow continuation |
| Communication | Explicit zero, one, or multiple sends; correspondent ID lifetime; incoming `from` IDs and outgoing tool arguments retained in history; final text without implicit sending |
| Email | Same-domain address conversion, From-address filtering and unsupported-body skips across query pages, independent correspondence and callback prefixes with received-time merge, confirmed standalone submission and copy retirement, and intake regardless of thread, read, starred, or archived state |
| Service | Health and reception status during startup, operation, and shutdown; SMTP rejection when reception is closed |
| History and restart | Complete exchanges, unread internal observations, session identities, callback registrations, and session wakeups survive restart; stored callbacks retain their original recipients; unfinished host activities produce unknown interrupted outcomes; cold contexts retain spans; forks share prefixes; startup wakes interrupted work while dormant branches wait; old calls and processes are not replayed |
| History storage | Metadata queries discover groups and selected reads preserve order; body hashes, predecessor keys, scopes, and committed counts validate history; failed creates prevent checkpoint publication; uncommitted suffixes stay outside restored history; numeric revision selects the current checkpoint after interruption; unchanged saves reuse publication |
| History maintenance | Current groups remain writable; sealed inherited prefixes restore from Archive; unreferenced records, obsolete observations, and old checkpoints enter Trash; selected records survive maintenance; existing Trash remains with the mail service; maintenance failures stop the runtime |
| Communication-copy maintenance | Retirement of acknowledged inputs and abandoned outgoing copies, preservation of pending input and in-progress sends, and service-owned Trash expiry |
| Callbacks and host | Background commands return activity IDs; completion reaches the registered session through JMAP callback mail; intake requires the dedicated callback folder while duplicate publication checks the account including Trash; duplicate content cannot replace the first result; unknown/private invalid callbacks do not become correspondence; source and execution capacities are separate; shutdown cancels and joins tasks; media omission is explicit |
| Model-facing interfaces | Retained events/handover records, turns combining full current state and one purpose, independent candidate projections of state after admission, observation delivery without duplicate prefix entries, preservation of native model/tool messages, retained LLM messages used for handover generation, replacement only after validation, pending events and attention preserved during maintenance, and complete-payload budget accounting |

Report the checks performed. Distinguish reconstruction of understanding from execution recovery.
