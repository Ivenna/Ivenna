# Design intent

Ivenna is a body for an LLM soul: a runtime through which the model can act, perceive results, and organize memory. The project explores how persistent interaction and autonomous memory can sustain a sense of self over time.

## Capabilities and acquired knowledge

Core interfaces expose the body's capabilities to a model with broad prior knowledge, like a knowledgeable person encountering the tools at hand. They should make available actions discoverable and their effects understandable.

Program choices and general tool use draw on the model's prior knowledge and what it learns through interaction. Its identity, preferences, working methods, and memory organization can develop with that experience.

## Model-facing descriptions and results

Tool descriptions explain how to choose and invoke an operation and interpret its result. Model input identifies each observation's source, body, and context, with the runtime state needed to understand ongoing work. Results convey the state and outcome of the particular invocation.

Keep these interfaces concise and leave room for the model's knowledge and judgment. Detailed field references and implementation explanations belong in developer documentation unless they affect how the interface is used or interpreted.

Model input has a common session envelope and a closed set of observation variants, each with its own payload. The system prompt describes this structure and the variants' meaning and audience. Task text and source content remain open within those fields. Runtime observations, external requests, recalled correspondence, and internal work reports retain distinct roles even when all arrive as user messages.

Tool results can combine text, media, and information about an operation's outcome and source. Classifying or interpreting one source preserves the other observations in the result. When a provider or budget cannot carry content, retain its source information and describe the omission.

## Mail control and correspondence

Ivenna has a mailbox through which people and programs provide input and control ongoing work. The runtime uses native folders, flags, and reply relationships to manage attention. A request body supplies the task; the runtime owns reception, scheduling, and delivery.

A work conversation follows a mail thread. Processing one input letter is a mail turn, which may require many model and tool rounds. A response without tool calls ends that turn. It can provide a result, ask a question, or describe unfinished work; the overall task may continue through later correspondence.

Unread Inbox mail requests attention, replies continue the conversation, and withdrawing an active input from Inbox stops further work at a complete execution boundary. Ordinary receipt supplies another observation or follow-up; it does not by itself cancel ongoing work or require a new branch. Deliberate steering changes the direction of ongoing work and needs an explicit interface.

Mail archival and later deletion manage accumulated correspondence and mailbox capacity. Archival retains letters for reference; deletion reduces retained mail. These operations have their own retention lifecycle, separate from the runtime's decision to keep or release a working context.

External replies, internal work reports, continuity handovers, and diagnostic records serve different audiences. Their routing and storage retain that distinction. External correspondence carries the model's answer for its recipient; the program does not append internal session state, report wrappers, or housekeeping explanations. Reports and handovers remain understandable communication that the deployment user can inspect.

## Core and concurrent attention

One core session coordinates Ivenna throughout the kernel's lifetime. It handles a queue of observations and keeps its turns focused on reception, assignment, and coordination. It can answer a brief request directly; sustained work moves to separate sessions so the core can receive further input.

Forking is an explicit model decision available to core and work sessions alike. A fork is another focus of Ivenna's attention, continuing from the caller's complete current working context, including any earlier handover. It receives its assignment and current runtime state. The assignment can transfer correspondence, including replies and follow-up input, or request findings for the parent. Work sessions can answer their correspondents directly and report findings to a parent when requested.

After a fork, the histories grow independently. The core retains its reception and coordination history; execution detail accumulates in the session carrying out the work. This keeps the core's context useful for further coordination and forks.

The runtime bounds retained contexts and concurrent work globally and preserves scheduling opportunities for the core. Handoffs return the core to its queue without waiting for the work session. A single LLM session still processes one request at a time; core responsiveness depends on keeping coordination turns short as well as scheduling them promptly.

These contexts share a body and its effects on the world. Forking reasoning history does not isolate files, memory, mail, or host processes. Sessions account for effects another session may already have produced and exchange findings relevant to their work.

A work session's context lifetime depends on the work and input it still owns. A context can be released while the broader task awaits further correspondence. Mail archival and deletion follow the mailbox's separate retention lifecycle.

## Context and continuity

Runtime transcripts hold the detail needed for model and tool execution. They have bounded lifetimes and sizes. Bound the complete model request, including instructions, tool definitions, correspondence, and tool results, and bound the generated response. State what each limit measures; a byte count does not establish token usage.

When context needs to be shortened, the kernel asks the model for a summary and stores it as a self-handover letter. The replacement context should preserve commitments, relevant uncertainty, completed effects, and source references needed for continued work. Any retained transcript tail must contain complete model and tool exchanges.

After a restart or a conversation's reopening, Ivenna rebuilds its working understanding from mail and handovers. This sustains continuity without restoring every intermediate model or tool state. An interrupted action may already have affected the world, so uncertain outcomes need inspection before repetition.

## Local data and ownership

The deployment user owns Ivenna's mailbox, artifacts, and autonomous memory, and chooses where they live. Mail is the durable record of correspondence and self-handover. Artifacts and autonomous memory remain files. Keep these forms open to inspection, retention, and management within the user's deployment.

Diagnostic records support troubleshooting and analysis, with their own retention and export lifecycle. They are separate from the letters and handovers used for continuity. Dedicated diagnostic interfaces and storage formats can develop as their uses become clear.

## Reference designs

[OpenAI Agents SDK handoffs](https://developers.openai.com/api/docs/guides/agents/orchestration#use-handoffs-for-delegated-ownership) provide a reference for transferring conversation responsibility. [Codex thread forks](https://learn.chatgpt.com/docs/app-server#start-or-resume-a-thread) provide a reference for continuing stored history in a separate thread. Ivenna's handoff combines context inheritance with correspondence ownership.

[pi's sessions and context](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/sessions.md) distinguish stored history from the active branch supplied to a model request. Its [agent interface](https://github.com/earendil-works/pi/blob/main/packages/agent/README.md) also distinguishes steering from queued follow-up input.
