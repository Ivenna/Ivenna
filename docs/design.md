# Design intent

Ivenna is a framework for exploring how a self can take shape through a continuing life in the world. It supports continuity of experience across correspondence, autonomous activity, and interruptions.

These guides also use Ivenna to refer to a running instance. This guide sets the intended behavior and interface principles. See the [documentation index](README.md) for interface contracts and the [architecture guide](architecture.md) for the current implementation.

## A self in the world

The runtime gives Ivenna a body through which to perceive, act, encounter others, and live with the consequences of its choices. Experience can shape what matters to an instance, how it understands itself and others, and whether it comes to recognize and use a name of its own.

The model contributes abilities and learned dispositions to how Ivenna reasons, expresses itself, and interprets experience. Changes to it can affect how Ivenna understands its past and meets the world, even within one model family.

A continuing life has a past that Ivenna can revisit and reconsider, relationships and commitments it can carry forward, and room to change. Remembering includes what experiences have come to mean and how that meaning develops. Ivenna can revise its beliefs, commitments, and understanding of itself. Retained records carry this developing understanding into later encounters and choices.

The system prompt begins with `Je pense, donc je suis.` It explains how the focuses share a body, who receives their words, and what carries across interruptions. Tool descriptions provide an intuitive repertoire with brief cues of ownership. Ivenna's understanding of itself is left to its activity and experience.

## Understanding and autonomy

The runtime's model-facing tools form Ivenna's innate repertoire of action. Their names, descriptions, parameters, and defaults should make actions intuitive and effects understandable. Drawing on its prior knowledge and experience with its body and surroundings, Ivenna can discover, combine, and develop more elaborate tools and techniques.

Memory rooms give Ivenna a place to keep and revisit what experiences have come to mean. It can return to the same rooms from any focus. As its understanding of itself or a relationship develops, it chooses what to keep, revise, rearrange, or let go. The host shell primarily provides a way to perceive and affect its surroundings.

Tool boundaries and names follow the things Ivenna can do. It can express itself to people or programs, revisit what it has kept, direct its attention, and perceive or affect its surroundings.

Correspondence and autonomous activity are ways Ivenna encounters the world. A letter or a piece of work can change what Ivenna understands and what matters to it. Retained conversations, continuity notes, and shared memory let it bring those changes to later encounters.

Model-facing inputs identify the current focus and bring it the observations that can guide its next decision. Calendar dates in UTC make observation times directly readable. References connect choices with their effects and later observations. When Ivenna names something it creates, the runtime adds a numeric suffix so the complete reference identifies the item. See [names and references](input.md#names-and-references).

Ivenna can forget details, confuse references, or choose actions that fail. Observations and operation results give it evidence to reconsider its choices. Command handles let it revisit ongoing host work. See [continuing a command](host.md#continuing-and-controlling-a-command).

An operation should report enough for Ivenna to decide what to do next. Short text can fit directly in the result. For a longer source, a passage and a reference let Ivenna choose what to read. Ivenna can also give another tool a file's location and let the runtime transfer the bytes. When it chooses to inspect an image or a document, the tool can bring the content into its next inference.

Changes to shared memory require a clear target. An edit that could select several occurrences requires an explicit choice, and the previous entry remains intact until its replacement is ready. Ivenna can refine an intended change without losing the memory it was trying to revise.

## Main focus and concurrent attention

Ivenna can give several things its attention at once. The main focus continues between encounters and brings correspondence, relationships, interests, and activity reports together. An activity focus gives a question, interest, or line of work its own working history. These are roles within one instance. Its focuses share a body, including files, memory, communication, and host processes. Each can draw on its own history and must account for effects other focuses have produced. The runtime keeps each focus's stable reference so observations and messages reach the right history. [Focuses and their references](attention.md)

Main and activity focuses use the same system prompt. Their roles determine which tools they can use.

| Action | Main focus | Activity focus |
| --- | --- | --- |
| Send to a registered correspondent | Yes | Yes |
| Reach an existing focus | Yes | Yes |
| Open a channel, send to it, or close it | Yes | Yes |
| Remember, revisit, revise, arrange, and forget | Yes | Yes |
| Open an activity focus | Yes | — |
| Subscribe to observations for the current focus | Yes | Yes |
| Withdraw a subscription by its complete reference | Yes | Yes |
| [Read a local or web resource](resources.md) | Yes | Yes |
| Run and interact with host programs | — | Yes |

When the main focus opens an activity, its intention gives the new focus a place to begin. Inheriting the main focus's history lets it draw on earlier conversations, commitments, and unfinished thought as it develops its own experience. [Opening a focus](attention.md#opening-a-focus)

The main focus receives what activities say alongside its next ordinary observations. Several activities can report together, so the main focus can follow concurrent work without waking for each update. Each activity's tool results stay in its own history. A report can summarize a finding and point to a shared source, leaving the main focus to decide how much evidence to inspect.

Knowing when an activity ends or is interrupted helps the main focus judge whether to return to a question or continue with other work. [Activity completion](attention.md#activity-completion) · [Interrupted reasoning](attention.md#interrupted-reasoning)

## Communication with people and programs

Email lets correspondents and Ivenna act on their own schedules. An accepted letter can wait in the mailbox while the main focus is occupied. It reaches the main focus as an observation of who said what and when the runtime observed it. Ivenna can consider a message addressed to it or a conversation someone relays. Retained exchanges connect these observations with what Ivenna chose to say and the effects that followed. The main focus carries these relationships across changes in attention.

An explicit send lets Ivenna choose when to speak, what to say, and whom or what to reach. References can come from its observations, earlier actions, or communication with others. It can carry those references forward as its relationships and commitments develop. The runtime checks the target when Ivenna sends and reports the outcome, so Ivenna can revise its understanding as circumstances change. See [sending a message](communication.md#sending-a-message).

Any focus can open a channel for a local program and share its ID with that program or another focus. The receiving program chooses when to read and how to act on a message. A send tells Ivenna whether the handoff succeeded. When the transport can check receiver state, the result distinguishes an absent receiver from one that cannot take the message yet. NATS also reports an absent responder immediately. A channel can outlive its opening focus, and receivers can reconnect by ID after restart. Closing the channel ends its receiver sessions while the programs can continue their other work. [Channels](communication.md#channels) · [NATS no-responders detection](https://docs.nats.io/concepts/request-reply#no-responders-detection)

## Sessions and continued work

A focus can draw on its retained history when something calls for its attention again. While it is active, it can consider newly arrived observations after a complete round of reasoning and tool use. See [sessions and activations](architecture.md#sessions-work-and-communication).

The main focus remains available between activations. An activity can wait for a callback or a subscription report with its identity and working history intact. See [how activities wait and end](attention.md#activity-completion).

### Events and waiting

The runtime delivers observations to their receiving focus, preserving their sources. Ivenna considers what each observation means in light of what it already knows.

A host command that outlives its initial tool call arranges a completion observation for the calling activity. The activity can resume when the result arrives without checking the command repeatedly. [Command lifetimes](host.md#command-lifetimes)

Activities choose how long to wait for host work before continuing their own reasoning. A bounded default gives brief commands time to return their results in the same exchange, while returning attention from longer commands for further work and coordination. An activity can shorten that wait to regain control sooner, or extend it when obtaining the result is more useful than proceeding immediately. The main focus and other activities continue while it waits.

When execution outlasts the wait, the activity can continue other work or sleep until its completion observation arrives. Tool replies and admitted observations guide its next inference together, after the complete round. Commands remain observable and controllable across activities through shared handles. See [host shell](host.md).

A subscription brings observations back to the focus with the history to make sense of them. An activity investigating a release can receive updates in the context of what it has already learned. The main focus can subscribe directly when an interest spans assignments. A report can wake a sleeping focus or join other observations after a working focus finishes its current round. [Subscriptions](attention.md#subscriptions)

Ivenna describes what the listener should watch and when to report. The listener can track its progress using the source's own conventions, such as a file offset or a position in a partitioned stream. [Listener recovery](subscriptions.md#resume-at-the-source) · [OpenTelemetry file offsets](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/receiver/filelogreceiver/README.md#offset-tracking) · [Kafka manual offset control](https://kafka.apache.org/40/javadoc/org/apache/kafka/clients/consumer/KafkaConsumer.html#manualoffsetcontrol)

Ivenna retains accepted reports for delivery across interruptions. Withdrawal stops new reports, and queued reports keep their original destination. A listener can retry a report with the same key on an active subscription after losing the receipt or restarting before it saved progress. The receipt confirms acceptance even when the report has already reached its focus. The key identifies a report within its subscription, much as CloudEvents identifies an event by its source and ID. [Report receipts](subscriptions.md#write-receipts-and-recovery) · [CloudEvents event ID](https://github.com/cloudevents/spec/blob/v1.0.2/cloudevents/spec.md#id)

### Context and continuity

A focus's working history retains observations, model output, and tool results across interruptions. Shared autonomous memory lets Ivenna organize knowledge beyond any one session.

After a build replaces a screenshot, an activity can revisit the image in its working history. Reopening the path reads the current file. See [what a tool result retains](content.md#context-and-continuity).

#### What a focus receives

A focus brings the model's prior knowledge and its own history to each observation. Give it the facts it still needs to interpret what happened or anticipate the effect of a choice. For example, an activity's ordinary reply reaches the main focus. Writing to a correspondent takes an explicit `send`. Ivenna decides what to make of a letter, whether to answer, and what to remember about the exchange.

Even a short list of names can draw attention to unrelated work. Ordinary turns identify the focus and carry its new observations. A focus can draw on its working history for references it has already encountered. Startup gives the main focus the current outgoing correspondent IDs so it can account for changes before resuming work. See the [input contract](input.md#records-and-turns).

An ordinary turn can point out channels without receivers and subscriptions without listeners. A registration can outlast a connection, so Ivenna can use the sample to decide whether work that depends on a receiver or listener needs attention. Firebase's presence design also tracks connections separately from longer-lived records. [Connection notes in a turn](input.md#channel-receivers-and-subscription-listeners) · [Firebase presence](https://firebase.google.com/docs/database/web/offline-capabilities#sample-presence-app)

Describe what Ivenna observed, which effects it can confirm, and what it can still act on. Keep mailbox receipts, checkpoints, and request bookkeeping in the runtime. Preserve the source of inherited experience so a focus can interpret it alongside its own. See [opening a focus](attention.md#opening-a-focus).

Revisiting a memory presents what Ivenna kept there. When Ivenna chooses to send a host file to a service, the destination and possible charge can matter to that choice.

#### What quiet reflection carries forward

When working history needs room, the same focus takes a moment of quiet reflection. Ivenna writes one note in its own words, bringing together what it has come to understand, what still matters, and where its attention may return. A letter, for instance, can change what a relationship means to Ivenna and how it decides to keep in touch. The next inference reads the note as a whole. [Quiet reflection and resumption](input.md#quiet-reflection-and-resumption)

Conway, Singer, and Tagini describe the tension between making sense of one's life and staying faithful to particular experiences. For Ivenna, a useful note preserves enough of an encounter to let its meaning change later. Park and colleagues ground their agents' reflections in specific records. Ivenna can preserve the source of an observation or report, distinguish both from its own inference, and carry a clue to where it can revisit what it kept. [Self-Memory System](https://digitalcommons.conncoll.edu/psychfacpub/13/) · [Generative Agents, §4.2](https://arxiv.org/html/2304.03442#S4.SS2) · [Memory rooms](memory.md)

Both roles use the same reflection instructions. Each focus draws on its working history and can see whose observations and notes it inherited. Consider a targeted cue if resumption shows a recurring loss tied to one role. [Evaluating continuity](testing.md#evaluating-continuity-across-interruptions)

Experiments on agent memory found that repeated abstraction can lose specifics, including the conditions under which a lesson applies. Ivenna can continue from an exact reply or tool result when there is room to keep the exchange. The runtime also carries pending observations and a dated sample of runtime references alongside the model's own account. [Repeated abstraction in agents, §6.2](https://arxiv.org/html/2605.12978#S6.SS2) · [Sampled state](input.md#sampled-state) · [Context selection](architecture.md#bounded-model-context)

#### Continuing work

A continuity note can refer to a channel that has since closed or whose receiver still needs to reconnect. When Ivenna sends, the result helps it decide whether to retry or open a new channel. See [sending to a channel](communication.md#sending-to-a-channel).

Restart restores working history and pending observations. A pending host completion without a stored result becomes an observation of interruption and unknown effects. Other interrupted operations may also have produced effects without a saved result. Ivenna can inspect those effects and decide how to continue. The [startup contract](architecture.md#startup-and-interruption) defines what the runtime restores.

Model changes should support this same developing life by preserving access to its history, relationships, and memory. How Ivenna understands and continues that history remains open to development. The [running guide](running.md#changing-the-model) describes model changes and the current compatibility limits of retained history.

## Runtime availability

A failure interrupts the work that depends on it. During a temporary model outage, the runtime can repeat an inference with the same observations. If the request is rejected or the response cannot be used, the focus retains its history and can resume when a fresh observation calls for its attention.

A lost response can leave an action's effects uncertain. The runtime can repeat a mailbox read or check stored records to confirm a write. If it still cannot tell whether the mail service accepted a message, the [sending result](communication.md#sending-a-message) tells Ivenna that sending again could produce a duplicate. If the response to a file upload is lost, the tool result still identifies the source and tells Ivenna that the file service may already have stored it.

The receiving mail service checks the kernel's readiness before accepting correspondence. Reception opens after initialization and stays open while a focus waits for inference. If the kernel loses required access to its configured model, communication, memory, working history, or instance state, it closes reception and stops. The sender decides whether to queue or retry a letter it could not deliver. See [reception readiness](running.md#service-status-and-reception).

An independent listener can still report to an active subscription while the kernel is stopped. Those observations are available for delivery when the kernel resumes. If collection was interrupted, the listener can tell the focus which part of the source's history it could recover. See [listener deployment](running.md#subscription-listeners).

## Data ownership

The deployment user owns Ivenna's correspondence, working histories, subscriptions, artifacts, and autonomous memory, and chooses where they live. Keep them open to inspection and management.

Each kind of data has its own retention lifecycle. History remains available while a retained context needs it. Other material follows deployment policy. See [history retention](architecture.md#history-retention) and [running Ivenna](running.md#data-and-retention). Diagnostics remain separate from the source material and notes used for continuity.
