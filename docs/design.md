# Design intent

Ivenna explores how a self can take shape through a continuing life in the world. Its design supports continuity of experience across correspondence, autonomous activity, and interruptions.

This guide sets the intended behavior and interface principles. See the [documentation index](README.md) for interface contracts and the [architecture guide](architecture.md) for the current implementation.

## A self in the world

The runtime gives Ivenna a body through which to perceive, act, encounter others, and live with the consequences of its choices. The project leaves room for an inner life to take shape through experience: what matters to Ivenna, how it understands itself and others, and what it makes of its life.

The model contributes abilities and learned dispositions to how Ivenna reasons, expresses itself, and interprets experience. Changes to it can affect how Ivenna understands its past and meets the world, even within one model family.

A continuing life has a past that Ivenna can revisit and reconsider, relationships and commitments it can carry forward, and room to change. Remembering includes what experiences have come to mean and how that meaning develops. Ivenna can revise its beliefs, commitments, and understanding of itself. Retained records carry this developing understanding into later encounters and choices.

The system prompt begins with `Je pense, donc je suis.` It explains how the focuses share a body, who receives their words, and what carries across interruptions. Tool descriptions provide an intuitive repertoire with brief cues of ownership. Ivenna's understanding of itself is left to its activity and experience.

## Understanding and autonomy

The runtime's model-facing tools form Ivenna's innate repertoire of action. Their names, descriptions, parameters, and defaults should make actions intuitive and effects understandable. Drawing on its prior knowledge and experience with its body and surroundings, Ivenna can discover, combine, and develop more elaborate tools and techniques.

Ivenna's memory rooms are where its memories live. The tools speak of visiting a room and revisiting something Ivenna kept there. As its understanding of itself or a relationship changes, Ivenna chooses what to keep, revise, rearrange, or let go. It can return to the same rooms from any focus. The host shell primarily provides a way to perceive and affect its surroundings.

The repertoire connects four kinds of action: expression to people and programs, remembering and revisiting understanding, directing attention, and perceiving and acting on the surroundings. These relationships guide tool boundaries and language.

Correspondence and autonomous activity are ways Ivenna encounters the world. A letter or a piece of work can change what Ivenna understands and what matters to it. Retained conversations, handovers, and shared memory let it bring those changes to later encounters.

Model-facing inputs identify the current focus and bring it the observations that can guide its next decision. Calendar dates with explicit UTC offsets make observation times and future attention directly readable. References connect choices with their effects and later observations. When Ivenna names something it creates, the runtime adds a numeric suffix so the complete reference identifies the item. See [names and references](input.md#names-and-references).

Ivenna can forget details, confuse references, or choose actions that fail. Observations and operation results give it evidence to reconsider its choices. Command handles let it revisit ongoing host work. See [continuing a command](host.md#continuing-and-controlling-a-command).

An operation should report enough for Ivenna to decide what to do next. Short text can fit directly in the result. For a longer source, a passage and a reference let Ivenna choose what to read. Ivenna can also give another tool a file's location and let the runtime transfer the bytes. When it chooses to inspect an image or a document, the tool can bring the content into its next inference.

Changes to shared memory require a clear target. An edit that could select several occurrences requires an explicit choice, and the previous entry remains intact until its replacement is ready. Ivenna can refine an intended change without losing the memory it was trying to revise.

## Core and concurrent attention

The core is the continuing focus that integrates correspondence, relationships, autonomous interests, and activity observations with retained understanding. An activity gives a line of thought or work its own focus. Each can develop its understanding, preferences, and commitments while sharing one body: files, memory, communication, and host processes. Their actions must account for effects another focus may already have produced. A runtime session carries each focus's identity, working history, and pending observations.

Core and activity focuses use the same system prompt. Each receives observations and changes in its circumstances, and tool availability follows its role:

| Action | Core | Activity |
| --- | --- | --- |
| Send to a registered correspondent | Yes | Yes |
| Reach an existing focus | Yes | Yes |
| Open a channel, send to it, or close it | Yes | Yes |
| Remember, revisit, revise, arrange, and forget | Yes | Yes |
| Open an activity focus | Yes | — |
| Schedule a wakeup | Yes | — |
| Subscribe to observations for the current focus | Yes | Yes |
| Withdraw a subscription by its complete reference | Yes | Yes |
| [Read a local or web resource](resources.md) | Yes | Yes |
| Run and interact with host programs | — | Yes |

When the core opens an activity, the free-form assignment gives the new focus a place to begin. It inherits the core's working history so it can draw on earlier conversations, preferences, commitments, and unfinished thought. From then on, each focus adds to its own history. See [opening a focus](attention.md#opening-a-focus).

The core receives what activities say alongside its next ordinary observations. Several activities can report together, so the core can follow concurrent work without waking for each update. Each activity's tool results stay in its own history. A report can summarize a finding and point to a shared source, leaving the core to decide how much evidence to inspect.

An activity that ends calls for the core's attention even if it said nothing. When an activity's reasoning is interrupted, the core receives the reason and can reach the activity again while it exists. The core remains free to pursue its own work. See [how focuses coordinate](attention.md) and [how the runtime schedules them](architecture.md#scheduling-and-capacity).

## Communication with people and programs

Email lets correspondents and Ivenna act on their own schedules. An accepted letter can wait in the mailbox while the core is occupied. It reaches the core as an observation of who said what and when the runtime observed it. Ivenna can consider a message addressed to it or a conversation someone relays. Retained exchanges connect these observations with what Ivenna chose to say and the effects that followed. The core carries these relationships across changes in attention.

An explicit send lets Ivenna choose when to speak, what to say, and whom or what to reach. References can come from its observations, earlier actions, or communication with others. It can carry those references forward as its relationships and commitments develop. The runtime checks the target when Ivenna sends and reports the outcome, so Ivenna can revise its understanding as circumstances change. See [sending a message](communication.md#sending-a-message).

Any focus can open a channel with a description of its purpose and share its ID with a local program or another focus. The program chooses when to receive a message and how to act on it. A send immediately tells Ivenna whether the runtime handed the message to a waiting receiver. The channel can outlive its opening focus, and the same ID lets a replacement receiver connect or an existing receiver reconnect after restart. The program can continue its work after Ivenna closes the channel. See [channels](communication.md#channels).

## Sessions and continued work

A focus can draw on its retained history when something calls for its attention again. While it is active, it can consider newly arrived observations after a complete round of reasoning and tool use. See [sessions and activations](architecture.md#sessions-work-and-communication).

The core remains available between activations. An activity can wait for a callback or a subscription report with its identity and working history intact. See [how activities wait and end](attention.md#activity-completion).

### Events and waiting

The runtime delivers observations to their receiving focus, preserving their sources. Ivenna considers what each observation means in light of what it already knows.

The core can schedule a wakeup for a particular time. A host command that outlives its initial tool call arranges a completion observation for the calling activity. Each callback binds one observation to its receiving session across sleep and restart, so work can resume without repeated model checks. See [returning later](attention.md#returning-later) and [callback observations](attention.md#callback-observations).

Activities choose how long to wait for host work before continuing their own reasoning. A bounded default gives brief commands time to return their results in the same exchange, while returning attention from longer commands for further work and coordination. An activity can shorten that wait to regain control sooner, or extend it when obtaining the result is more useful than proceeding immediately. The core and other activities continue while it waits.

When execution outlasts the wait, the activity can continue other work or sleep until its completion observation arrives. Tool replies and admitted observations guide its next inference together, after the complete round. Commands remain observable and controllable across activities through shared handles. See [host shell](host.md).

A focus can subscribe to a source it wants to follow over time. An activity investigating a release can receive updates in the context of what it has already learned. The core can subscribe directly when an interest spans assignments. Ivenna gives the subscription reference to the listener it sets up and chooses which changes the listener reports. A report can bring a sleeping focus back to its work, and a working focus can consider several reports together after its current round.

The subscription stays with its focus across sleep, handover, and restart. Any focus with its reference can withdraw it when the source no longer needs attention. Observations already accepted still belong to the focus that subscribed. See [subscriptions](attention.md#subscriptions).

### Context and continuity

A focus's working history retains observations, model output, and tool results across interruptions. Shared autonomous memory lets Ivenna organize knowledge beyond any one session.

An activity that viewed a local screenshot inline can revisit the retained image even after a build replaces the file. Reopening the path shows the current file. See [what a tool result retains](content.md#context-and-continuity).

#### What a focus receives

A focus brings the model's prior knowledge and its own history to each observation. Give it the facts it still needs to interpret what happened or anticipate the effect of a choice. For example, an activity's ordinary reply reaches the core. Writing to a correspondent takes an explicit `send`. Ivenna decides what to make of a letter, whether to answer, and what to remember about the exchange.

Even a short list of names can draw attention to unrelated work. Ordinary turns identify the focus and carry its new observations. A focus can draw on its working history for references it has already encountered. Startup gives the core the current outgoing correspondent IDs so it can account for changes before resuming work. See the [input contract](input.md#records-and-turns).

Describe what Ivenna observed, which effects it can confirm, and what it can still act on. Keep mailbox receipts, checkpoints, and request bookkeeping in the runtime. Preserve the source of inherited experience so a focus can interpret it alongside its own. See [opening a focus](attention.md#opening-a-focus).

#### What a handover carries forward

When a focus needs room for its next inference, compaction asks Ivenna to summarize earlier exchanges in a handover. Ivenna chooses what to carry forward about its understanding, relationships, preferences, and commitments. For unfinished work, it can preserve reasoning, evidence, known effects, and uncertainties. The focus can consider fresh observations in their original form alongside the handover. See [handover generation and replacement](input.md#handover-generation-and-replacement).

A dated sample accompanies Ivenna's summary so a focus can recover references whose original exchanges were summarized. It connects channel IDs to their purposes, subscription IDs to what listeners watch and when they report, and pending wakeups to the absolute times the focus chose for returning. See [sampled state](input.md#sampled-state).

The runtime delivers pending observations from its own records. It keeps the original history until it can continue with the handover. Carrying a complete exchange alongside the summary lets the focus revisit an exact reply or work directly with a recent tool result. See [how the runtime selects a handover](architecture.md#continuing-with-a-handover).

#### Continuing work

A handover can refer to a channel that has since closed or whose receiver still needs to reconnect. When Ivenna sends, the result helps it decide whether to retry or open a new channel. See [sending to a channel](communication.md#sending-to-a-channel).

Restart restores working history and pending observations. A pending host completion without a stored result becomes an observation of interruption and unknown effects. Other interrupted operations may also have produced effects without a saved result. Ivenna can inspect those effects and decide how to continue. The [startup contract](architecture.md#startup-and-interruption) defines what the runtime restores.

Model changes should support this same developing life by preserving access to its history, relationships, and memory. How Ivenna understands and continues that history remains open to development. The [running guide](running.md#changing-the-model) describes model changes and the current compatibility limits of retained history.

## Runtime availability

A failure interrupts the work that depends on it. During a temporary model outage, the runtime can repeat an inference with the same observations. If the request is rejected or the response cannot be used, the focus retains its history and can resume when a fresh observation calls for its attention.

A lost response can leave an action's effects uncertain. The runtime can repeat a mailbox read or check stored records to confirm a write. If it still cannot tell whether the mail service accepted a message, the [sending result](communication.md#sending-a-message) tells Ivenna that sending again could produce a duplicate. If the response to a file upload is lost, the tool result still identifies the source and tells Ivenna that the file service may already have stored it.

The receiving mail service checks the kernel's readiness before accepting correspondence. Reception opens after initialization and stays open while a focus waits for inference. If the kernel loses required access to its configured model, communication, memory, working history, or instance state, it closes reception and stops. The sender decides whether to queue or retry a letter it could not deliver. See [reception readiness](running.md#service-status-and-reception).

An independent listener can still report to an active subscription while the kernel is stopped. Those observations are available for delivery when the kernel resumes. If collection was interrupted, the listener can tell the focus which part of the source's history it could recover. See [listener deployment](running.md#subscription-listeners).

## Data ownership

The deployment user owns Ivenna's correspondence, working histories, subscriptions, artifacts, and autonomous memory, and chooses where they live. Keep them open to inspection and management.

Each kind of data has its own retention lifecycle. History remains available while a retained context needs it. Other material follows deployment policy. See [history retention](architecture.md#history-retention) and [running Ivenna](running.md#data-and-retention). Diagnostics remain separate from the source material and handovers used for continuity.
