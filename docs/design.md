# Design intent

Ivenna is a body for an LLM soul: a runtime through which the model can act, perceive results, and organize memory. The project explores how persistent interaction and autonomous memory can sustain a sense of self over time. Ongoing communication and autonomous activity guide its interaction design.

This guide sets the intended behavior and interface principles. See the [documentation index](README.md) for interface contracts and the [architecture guide](architecture.md) for the current implementation.

## Understanding and autonomy

The model brings broad prior knowledge to the capabilities at hand. It chooses programs and tools through that knowledge and its experience with Ivenna's body. Interfaces should make available actions discoverable and their effects understandable.

Understanding, preferences, commitments, and working methods can develop through correspondence and autonomous activity. Ivenna chooses what to remember and how to organize shared autonomous memory wherever its attention is focused. Retained conversations, handovers, and memory support this continuing understanding.

Capabilities preserve operation outcomes, source descriptions, and supported media together. When content cannot be supplied, its source and the omission remain available for Ivenna to interpret.

## Core and concurrent attention

One core session coordinates Ivenna, relating correspondence to retained understanding and shared memory. The core and activity sessions are focuses of the same Ivenna; each can develop its own understanding, preferences, and commitments. They share one body: files, memory, communication, and host processes. Their actions must account for effects another session may already have produced.

Only the core can [fork an activity session](communication.md#forking-an-activity-session). An activity inherits the core's retained understanding and receives a free-form assignment to pursue from it. Inheritance carries relationships, preferences, and unfinished thought into the new focus. The core continues its own work while their histories grow independently.

Only the core can send direct session messages. Both roles can communicate externally and maintain autonomous memory; host tools belong to activities. An independent execution lane and short coordination turns support core responsiveness while activities pursue their work. See [scheduling and capacity](architecture.md#scheduling-and-capacity) for resource limits and dispatch.

## Communication with people and programs

Messages enter the core as observations of who said what, with correspondent IDs and observation time. Receiving one does not imply that Ivenna was addressed or must respond. Retained exchanges connect those observations with Ivenna's own choices and subsequent effects.

Ivenna chooses whether to communicate, to whom, and what to say through `send_message`. One arrival can lead to zero, one, or several outgoing messages. Internal reasoning and activity completion remain within Ivenna unless it chooses to send a message. The [communication guide](communication.md) defines external correspondence and session coordination.

## Sessions and continued work

A task describes work to accomplish. A session has a stable identity, retained understanding, and an event queue. Each activation continues a session's work through model/tool rounds, admitting further events between complete rounds so new information can guide the next decision without interrupting an inference or tool.

A response without tool calls ends the activation when no queued arrivals or core attention signal require more reasoning. At that boundary, an activity with pending callbacks waits with its identity and understanding retained; otherwise its session ends and the core receives a [completion report](communication.md#activity-completion). The core remains available between activations. Ivenna assesses task outcomes from the observations it has gathered.

### Events and waiting

Ivenna interprets observations; the runtime owns delivery and resumption. A known destination must not depend on a model remembering to relay a result or wake a waiting session. Messages preserve their actual sources for the receiver to weigh against its own evidence and understanding.

Sessions can schedule wakeups, and activities can receive results from background host commands. Sources bind to their receiving session before starting and retain that destination for their lifetime. This lets work continue without new correspondence. See [session communication](communication.md#session-communication-and-wakeups) and [background commands](host.md#background-commands).

Each inference receives a self-contained snapshot of the runtime facts exposed by the interface, including after restart or compaction. These facts place retained understanding in its current circumstances; task meaning remains in model messages, handovers, and memory.

### Context and continuity

Working contexts retain observations, model output, and tool results across interruption. Within a bounded context, [compaction](architecture.md#bounded-model-context) condenses retained exchanges into a handover that preserves self-understanding, preferences, commitments, uncertainty, effects, and the identities needed to continue. Shared autonomous memory lets Ivenna organize knowledge beyond a session's working history.

Restart restores saved understanding and pending work. Earlier actions remain evidence rather than instructions to replay: host processes are not restored and old tool calls are not repeated. Missing host outcomes become observations of interruption and uncertainty for Ivenna to interpret. The [startup contract](architecture.md#startup-and-interruption) defines reconstruction and its limits.

## Runtime availability

Communication and autonomous memory are required for Ivenna to operate. Infrastructure, model, and session-execution failures end the runtime and its concurrent work. Defined tool outcomes, such as a missing memory entry, a capacity limit, or a command's nonzero exit, remain observations for the model.

The receiving boundary checks Ivenna's reception status before accepting correspondence. Reception closes during startup, shutdown, or failure; sender retry and queuing belong to the sender. See [reception readiness](running.md#service-status-and-reception) for the precheck's limits.

## Data ownership

The deployment user owns Ivenna's correspondence, working histories, artifacts, and autonomous memory, and chooses where they live. Keep them open to inspection and management.

These stores have separate retention lifecycles. History remains available while a retained context needs it; other material follows deployment policy. See [history retention](architecture.md#history-retention) and [running Ivenna](running.md#data-and-retention). Diagnostics remain separate from the source material and handovers used for continuity.
