# Design intent

Ivenna is a body for an LLM soul: a runtime through which the model can act, perceive results, and organize memory. The project explores how persistent interaction and autonomous memory can sustain a sense of self over time. Ongoing communication and autonomous activity guide its interaction design.

This guide sets the intended behavior and interface principles. See the [documentation index](README.md) for interface contracts and the [architecture guide](architecture.md) for the current implementation.

## Understanding and autonomy

The runtime's model-facing tools form Ivenna's innate repertoire of action. Their names, descriptions, parameters, and defaults should make actions intuitive and effects understandable. Drawing on its prior knowledge and experience with its body and surroundings, Ivenna can discover, combine, and develop more elaborate tools and techniques.

Within this repertoire, memory rooms act directly on Ivenna's continuing understanding and sense of self; the host shell primarily provides a way to perceive and affect its surroundings. Memory actions and brief cues of ownership invite Ivenna to revisit earlier understanding, carry something forward, revise it, or let it go. Ivenna chooses what to retain and how to organize it wherever its attention is focused.

Correspondence and autonomous activity can both shape Ivenna's understanding, preferences, commitments, and working methods. Retained conversations, handovers, and shared memory support continuity as that understanding develops.

Capabilities keep operation outcomes connected to their sources and supported content. Bounded observations provide a way to inspect further content, and omissions remain distinguishable from an empty source. This lets Ivenna decide which evidence needs further inspection.

Changes to shared memory require a clear target. An edit that could select several occurrences requires an explicit choice, and the previous entry remains intact until its replacement is ready. Ivenna can refine an intended change without losing the memory it was trying to revise.

## Core and concurrent attention

One core session coordinates Ivenna, relating correspondence to retained understanding and shared memory. The core and activity sessions are focuses of the same Ivenna; each can develop its own understanding, preferences, and commitments. They share one body: files, memory, communication, and host processes. Their actions must account for effects another session may already have produced.

Only the core can [fork an activity session](communication.md#forking-an-activity-session). An activity inherits the core's retained understanding and receives a free-form assignment to pursue from it. Inheritance carries relationships, preferences, and unfinished thought into the new focus. The core continues its own work while their histories grow independently.

New assistant text from activities is collected for the core's ordinary inputs, allowing it to follow concurrent work without reasoning on every update. One input can present several activities while preserving each source's message order and observation times. The core interprets these expressions as what an activity said; they do not establish the effects of its tools.

An activity's ending always requests the core's attention, whether or not it produced text. Expressions and runtime state changes do not independently activate the core.

Only the core can send direct session messages and schedule wakeups. Both roles can communicate externally and maintain autonomous memory; host tools belong to activities. Core coordination must remain responsive while activities pursue their work. See [scheduling and capacity](architecture.md#scheduling-and-capacity) for the current dispatch and resource limits.

## Communication with people and programs

Messages enter the core as observations of who said what, with correspondent IDs and observation time. Receiving one does not imply that Ivenna was addressed or must respond. Retained exchanges connect those observations with Ivenna's own choices and subsequent effects.

Ivenna chooses whether to communicate, to whom, and what to say through `send_message`. One arrival can lead to zero, one, or several outgoing messages. Internal reasoning and activity completion remain within Ivenna unless it chooses to send a message. The [communication guide](communication.md) defines external correspondence and session coordination.

## Sessions and continued work

A task describes work to accomplish. A session has a stable identity, retained understanding, and an event queue. Each activation continues a session's work through model/tool rounds, admitting further events between complete rounds so new information can guide the next decision without interrupting an inference or tool.

A response without tool calls ends the activation when no queued arrivals require more reasoning. At that boundary, an activity with an observation still registered sleeps with its identity and understanding retained; otherwise its session ends and the core receives an [ending observation](communication.md#activity-completion). The core remains available between activations. Ivenna assesses task outcomes from the observations it has gathered.

### Events and waiting

Ivenna interprets observations; the runtime owns delivery and resumption. A known destination must not depend on a model remembering to relay a result or wake a waiting session. Messages preserve their actual sources for the receiver to weigh against its own evidence and understanding.

The core can arrange wakeups for later attention. Host commands that outlive their initial tool calls arrange completion observations for the calling activities. Each arrangement binds one observation to its receiving session across sleep and restart, so work can resume without repeated model checks. See [session communication](communication.md#session-communication-and-wakeups).

Activities choose how long to wait for host work before continuing their own reasoning. A bounded default gives brief commands time to return their results in the same exchange, while returning attention from longer commands for further work and coordination. An activity can shorten that wait to regain control sooner, or extend it when obtaining the result is more useful than proceeding immediately. The core and other activities continue while it waits.

When execution outlasts the wait, the activity can continue other work or sleep until its completion observation arrives. Tool replies and admitted observations guide its next inference together, after the complete round. Commands remain observable and controllable across activities through shared handles. See [host shell](host.md).

Each inference receives a self-contained snapshot of the runtime facts exposed by the interface, including after restart or compaction. These facts place retained understanding in its current circumstances; task meaning remains in model messages, handovers, and memory.

### Context and continuity

Working contexts retain observations, model output, and tool results across interruption. Within a bounded context, [compaction](architecture.md#bounded-model-context) condenses retained exchanges into a handover that preserves self-understanding, preferences, commitments, uncertainty, effects, and the identities needed to continue. Shared autonomous memory lets Ivenna organize knowledge beyond a session's working history.

Restart restores saved understanding and pending work. Host processes are not restored and old tool calls are not repeated. A pending host completion without a stored result becomes an observation of interruption and unknown effects. Other interrupted operations may also have produced effects without a saved result; Ivenna inspects uncertain effects before deciding how to continue. The [startup contract](architecture.md#startup-and-interruption) defines reconstruction and its limits.

## Runtime availability

Communication and autonomous memory are required for Ivenna to operate. Infrastructure, model, and session-execution failures end the runtime and its concurrent work. Defined tool outcomes, including unsuccessful or uncertain actions, remain observations from which Ivenna decides how to continue.

The receiving boundary checks Ivenna's reception status before accepting correspondence. Reception closes during startup, shutdown, or failure; sender retry and queuing belong to the sender. See [reception readiness](running.md#service-status-and-reception) for the precheck's limits.

## Data ownership

The deployment user owns Ivenna's correspondence, working histories, artifacts, and autonomous memory, and chooses where they live. Keep them open to inspection and management.

These stores have separate retention lifecycles. History remains available while a retained context needs it; other material follows deployment policy. See [history retention](architecture.md#history-retention) and [running Ivenna](running.md#data-and-retention). Diagnostics remain separate from the source material and handovers used for continuity.
