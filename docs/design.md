# Design intent

Ivenna is a body for an LLM soul: a runtime through which the model can act, perceive results, and organize memory. The project explores how persistent interaction and autonomous memory can sustain a sense of self over time.

## Capabilities and acquired knowledge

Core interfaces expose the body's capabilities to a model with broad prior knowledge, like a knowledgeable person encountering the tools at hand. They should make available actions discoverable and their effects understandable.

Program choices and general tool use draw on the model's prior knowledge and what it learns through interaction. Its identity, preferences, working methods, and memory organization can develop with that experience.

## Model-facing descriptions and results

Tool descriptions help the model choose an operation, invoke it, and interpret its result. Model input identifies the source, body, and context of each observation and supplies the runtime state needed to understand ongoing work.

Results convey the state and outcome of the particular invocation. Implementation explanations belong in developer documentation unless they affect how the interface is used or interpreted.

## Mail control and correspondence

Ivenna has a mailbox through which people and programs provide input and control ongoing work. The runtime uses native folders, flags, and reply relationships to manage attention. A request body supplies the task; the runtime owns reception, scheduling, and delivery.

A work conversation follows a mail thread. Processing one input letter is a mail turn, which may require many model and tool rounds. A response without tool calls ends that turn. It can provide a result, ask a question, or describe unfinished work; the overall task may continue through later correspondence.

Unread Inbox mail requests attention, replies continue the conversation, and withdrawing an active input from Inbox stops further work at a complete execution boundary. When a mail turn ends and no input remains queued, Ivenna records a handover and archives its processed letters. This releases the active conversation's resources while preserving a basis for reopening it.

Replies, branch reports, and self-handovers should remain understandable communication that a person can read and use. The runtime manages these letters through the mail service's existing semantics.

## Core and concurrent attention

One core perspective continues for the kernel's lifetime and remains available between model requests. A new conversation can use the free core context. While the core is occupied, independent work can fork a separate context from its most recent complete history.

These contexts share a body and its effects on the world. The kernel brings branch findings, completed actions, and outstanding questions back to the core through reports. The core incorporates what it learns into its current understanding.

Archiving a work conversation releases its branch context or its claim on the core. The core itself continues. A later reply can reopen the archived work from its own handover and correspondence.

## Context and continuity

Runtime transcripts hold the detail needed for model and tool execution. They have bounded lifetimes and sizes. Bound the complete model request, including instructions, tool definitions, correspondence, and tool results, and bound the generated response. State what each limit measures; a byte count does not establish token usage.

When context needs to be shortened, the kernel asks the model for a summary and stores it as a self-handover letter. The replacement context should preserve commitments, relevant uncertainty, completed effects, and source references needed for continued work. Any retained transcript tail must contain complete model and tool exchanges.

After a restart or a conversation's reopening, Ivenna rebuilds its working understanding from mail and handovers. This sustains continuity without restoring every intermediate model or tool state. An interrupted action may already have affected the world, so uncertain outcomes need inspection before repetition.

## Local data and ownership

The deployment user owns Ivenna's mailbox, artifacts, and autonomous memory, and chooses where they live. Mail is the durable record of correspondence and self-handover. Artifacts and autonomous memory remain files. Keep these forms open to inspection, retention, and management within the user's deployment.

Diagnostic records support troubleshooting and analysis, with their own retention and export lifecycle. They are separate from the letters and handovers used for continuity. Dedicated diagnostic interfaces and storage formats can develop as their uses become clear.
