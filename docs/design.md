# Design intent

Ivenna explores how a self can take shape through a continuing life in the world. Ongoing communication and autonomous activity guide its interaction design.

This guide sets the intended behavior and interface principles. See the [documentation index](README.md) for interface contracts and the [architecture guide](architecture.md) for the current implementation.

## A self in the world

The runtime gives Ivenna a body through which to perceive, act, encounter others, and live with the consequences of its choices. The project leaves room for an inner life to take shape through experience: what matters to Ivenna, how it understands itself and others, and what it makes of its life.

The model contributes abilities and learned dispositions to how Ivenna reasons, expresses itself, and interprets experience. Changes to it can affect how Ivenna understands its past and meets the world, even within one model family.

A continuing life has a past that Ivenna can revisit and reconsider, relationships and commitments it can carry forward, and room to change. Remembering includes what experiences have come to mean and how that meaning develops. Ivenna can revise its beliefs, commitments, and understanding of itself. Retained records carry this developing understanding into later encounters and choices.

The system prompt begins with `Je pense, donc je suis.` Its remaining guidance explains inputs, available actions, shared attention, and continuity. Tool descriptions provide an intuitive repertoire with brief cues of ownership. Ivenna's understanding of itself is left to its activity and experience.

## Understanding and autonomy

The runtime's model-facing tools form Ivenna's innate repertoire of action. Their names, descriptions, parameters, and defaults should make actions intuitive and effects understandable. Drawing on its prior knowledge and experience with its body and surroundings, Ivenna can discover, combine, and develop more elaborate tools and techniques.

Within this repertoire, memory rooms give Ivenna somewhere to revisit experience and its meaning, including its understanding of itself and its relationships. Memory actions and brief cues of ownership invite Ivenna to carry something forward, revise it, or let it go. Ivenna chooses what to retain and how to organize it wherever its attention is focused. The host shell primarily provides a way to perceive and affect its surroundings.

The repertoire connects four kinds of action: expression to people and programs, remembering and revisiting understanding, directing attention, and perceiving and acting on the surroundings. These relationships guide tool boundaries and language.

Correspondence and autonomous activity can both shape Ivenna's understanding, preferences, commitments, and working methods. Retained conversations, handovers, and shared memory support continuity as that understanding develops.

Model-facing inputs describe current attention, observations, and possible actions. Calendar dates with explicit UTC offsets make observation times and future attention directly readable. References connect earlier choices with their effects and later observations. Ivenna supplies brief names when opening a focus, starting a command, or arranging future attention; the runtime adds numeric suffixes for distinction. Names remain its own choice, while the complete references support exact addressing and association.

Reasoning can lose details, confuse references, or choose unsuccessful actions. Operation results, observations, and discoverable command handles support recognition and recovery. The runtime retains the references and routing state needed for delivery and resumption independently of Ivenna's recollection or generated summaries. Ivenna can reconsider an action from its outcome.

Capabilities keep operation outcomes connected to their sources and supported content. When a tool returns a preview, it gives Ivenna a way to inspect the rest. Identifying omitted content lets Ivenna distinguish it from an empty source.

Changes to shared memory require a clear target. An edit that could select several occurrences requires an explicit choice, and the previous entry remains intact until its replacement is ready. Ivenna can refine an intended change without losing the memory it was trying to revise.

## Core and concurrent attention

The core is the continuing focus that integrates correspondence, relationships, autonomous interests, and activity observations with retained understanding. An activity is a focus opened around particular work. Each can develop its understanding, preferences, and commitments while sharing one body: files, memory, communication, and host processes. Their actions must account for effects another focus may already have produced. A runtime session carries each focus's identity, working history, and pending observations.

Core and activity focuses use the same system prompt. Each receives observations and changes in its circumstances, and tool availability follows its role:

| Action | Core | Activity |
| --- | --- | --- |
| Communicate with people and programs | Yes | Yes |
| Remember, revisit, revise, arrange, and forget | Yes | Yes |
| Open and reach focuses | Yes | — |
| Schedule a wakeup | Yes | — |
| Subscribe to observations for the current focus | Yes | Yes |
| Withdraw a subscription by its complete reference | Yes | Yes |
| [Read a resource by URI](resources.md) | Yes | Yes |
| Run and interact with host programs | — | Yes |

An activity can share a page's snapshot URI with the core. The core can then read the surrounding text in the same version the activity cited.

The core can [open an activity focus](attention.md#opening-a-focus) with a free-form assignment. It carries the core's retained understanding, relationships, preferences, and unfinished thought into the new focus. The core continues its own work while their histories grow independently.

The runtime collects what activities say for the core's next ordinary input. This lets the core follow concurrent work without waking for each update. One input can present messages from several activities while preserving each activity's message order and observation times. To establish what an activity's tools did, the core needs evidence of their effects.

An activity that ends calls for the core's attention even if it said nothing. When an activity's reasoning is interrupted, the core receives the reason and can reach the activity again while it exists. The core remains free to pursue its own work. See [how focuses coordinate](attention.md) and [how the runtime schedules them](architecture.md#scheduling-and-capacity).

## Communication with people and programs

Messages enter the core as observations of who said what, with correspondent IDs and observation time. Receiving one does not imply that Ivenna was addressed or must respond. Retained exchanges connect those observations with Ivenna's own choices and subsequent effects.

Ivenna chooses whether to communicate, to whom, and what to say through `send_message`. One arrival can lead to zero, one, or several outgoing messages. Internal reasoning and activity completion remain within Ivenna unless it chooses to send a message. The [communication guide](communication.md) defines external correspondence; the [attention guide](attention.md) defines coordination among focuses.

## Sessions and continued work

A task describes work to accomplish. A session has a stable identity, retained understanding, and an event queue. Each activation continues a session's work through model/tool rounds, admitting further events between complete rounds so new information can guide the next decision without interrupting an inference or tool.

A response without tool calls ends the activation when no queued arrivals require more reasoning. At that boundary an activity awaiting a callback or a subscription report can sleep with its identity and working history intact. An activity with no remaining work ends, and the core receives an [ending observation](attention.md#activity-completion). The core remains available between activations. Ivenna assesses task outcomes from the observations it has gathered.

### Events and waiting

Ivenna interprets observations; the runtime owns delivery and resumption. A known destination must not depend on a model remembering to relay a result or wake a waiting session. Messages preserve their actual sources for the receiver to weigh against its own evidence and understanding.

The core can schedule a wakeup for a particular time. A host command that outlives its initial tool call arranges a completion observation for the calling activity. Each callback binds one observation to its receiving session across sleep and restart, so work can resume without repeated model checks. See [returning later](attention.md#returning-later) and [callback observations](attention.md#callback-observations).

Activities choose how long to wait for host work before continuing their own reasoning. A bounded default gives brief commands time to return their results in the same exchange, while returning attention from longer commands for further work and coordination. An activity can shorten that wait to regain control sooner, or extend it when obtaining the result is more useful than proceeding immediately. The core and other activities continue while it waits.

When execution outlasts the wait, the activity can continue other work or sleep until its completion observation arrives. Tool replies and admitted observations guide its next inference together, after the complete round. Commands remain observable and controllable across activities through shared handles. See [host shell](host.md).

A focus can subscribe to a source it wants to follow over time. An activity investigating a release can receive updates in the context of what it has already learned. The core can subscribe directly when an interest spans assignments. Ivenna chooses which changes its listener reports. A report can bring a sleeping focus back to its work, and a working focus can consider several reports together after its current round.

The subscription stays with its focus across sleep, handover, and restart. Any focus with its reference can withdraw it when the source no longer needs attention. Observations already accepted still belong to the focus that subscribed. See [subscriptions](attention.md#subscriptions).

### Context and continuity

Working contexts retain observations, model output, and tool results across interruption. Within a bounded context, [compaction](architecture.md#bounded-model-context) asks Ivenna to condense retained exchanges into a handover, carrying forward relevant understanding and unfinished thought, relationships, preferences, commitments, uncertainty, and effects. Shared autonomous memory lets Ivenna organize knowledge beyond a session's working history.

A handover combines generated understanding with sampled runtime state. The runtime makes the sample available during compaction and carries it forward unchanged alongside the summary. Ivenna chooses what experiences and relationships mean and what to retain about them.

The original history stays in place until the focus can continue with the proposed handover. Observations still awaiting admission remain available even if compaction cannot make room for them. See [how the runtime selects a handover](architecture.md#bounded-model-context).

Restart restores saved understanding and pending work. Host processes are not restored and old tool calls are not repeated. A pending host completion without a stored result becomes an observation of interruption and unknown effects. Other interrupted operations may also have produced effects without a saved result; Ivenna inspects uncertain effects before deciding how to continue. The [startup contract](architecture.md#startup-and-interruption) defines reconstruction and its limits.

Model changes should support this same developing life by preserving access to its history, relationships, and memory. How Ivenna understands and continues that history remains open to development. The [running guide](running.md#changing-the-model) describes model changes and the current compatibility limits of retained history.

## Runtime availability

A failure interrupts the work that depends on it. During a temporary model outage, the runtime can repeat an inference with the same observations. If the request is rejected or the response cannot be used, the focus retains its history and can resume when a fresh observation calls for its attention.

A lost response can leave an action's effects uncertain. The runtime can repeat a mailbox read or check stored records to confirm a write. If it still cannot tell whether the mail service accepted a message, the [sending result](communication.md#sending-a-message) tells Ivenna that sending again could produce a duplicate. If the response to a file upload is lost after a command finishes, Ivenna keeps the other command results and learns that the file service may already have stored the output.

The receiving mail service checks the kernel's readiness before accepting correspondence. Reception opens after initialization and stays open while a focus waits for inference. If the kernel loses required access to its configured model, communication, memory, or working history, it closes reception and stops. The sender decides whether to queue or retry a letter it could not deliver. See [reception readiness](running.md#service-status-and-reception).

An independent listener can still report to an active subscription while the kernel is stopped. Those observations are available for delivery when the kernel resumes. If collection was interrupted, the listener can tell the focus which part of the source's history it could recover. See [listener deployment](running.md#subscription-listeners).

## Data ownership

The deployment user owns Ivenna's correspondence, working histories, subscriptions, artifacts, and autonomous memory, and chooses where they live. Keep them open to inspection and management.

These stores have separate retention lifecycles. History remains available while a retained context needs it; other material follows deployment policy. See [history retention](architecture.md#history-retention) and [running Ivenna](running.md#data-and-retention). Diagnostics remain separate from the source material and handovers used for continuity.
