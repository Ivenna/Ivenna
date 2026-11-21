# Corresponding with Ivenna

Send messages to Ivenna while [reception is open](running.md#service-status-and-reception). Each arrival enters Ivenna's core independently. Include enough context for Ivenna to understand the message and relate it to ongoing work.

## Sending a request

Use a correspondent account in the same domain as Ivenna's configured address. Send through your mail service's authenticated submission path, with From set to an address that account is allowed to use. For example:

```text
From: operator@ivenna.test
To: ivenna@ivenna.test
Subject: French practice

Please remember that I am learning French and propose a practice plan.
```

Your mail service can report a delivery failure when Ivenna's [reception is closed](running.md#service-status-and-reception).

Ivenna reads your correspondent ID (`operator` in this example), subject, and message body. Each From address must map to a supported ID in the configured domain for Ivenna to receive the letter. To ask Ivenna to contact someone else, include their correspondent ID in the text. See [email addressing](communication.md#current-email-addressing).

Put material you want Ivenna to read in the subject or body. Ivenna reads the plain-text body when available, uses HTML source for HTML-only letters, and skips attachments. If a letter and the context needed to read it exceed the model request budget even after compaction, the letter stays in the mailbox and later correspondence waits behind it. See the operator's guide to [resolving an admission failure](running.md#recovering-from-an-admission-failure).

Ivenna decides whether and when to write. You may receive one response, several updates, or none. Read its messages in your mail client under the subject `Ivenna`.

For a command to verify the supplied local environment, see [sending a development message](../dev/README.md#sending-a-message).

## Continuing correspondence

Follow-up messages enter the core as new observations, including replies within an email thread. Identify the earlier request and describe the changes that should guide ongoing work. For example:

```text
From: operator@ivenna.test
To: ivenna@ivenna.test
Subject: French practice schedule

About the French practice plan: use Tuesday and Saturday, and keep each
session to 20 minutes. Please retain the vocabulary goals we agreed on.
```

## Ongoing work and memory

Ivenna can pursue work while receiving further messages and may consider several waiting messages together. Its activities can keep working or sleep while host commands run, then continue when results arrive. Their intermediate expressions accompany the core's ordinary inputs; their endings request its attention. The core can also arrange later attention without a new message from you. See [Attention](attention.md) for how these focuses coordinate. Processing depends on runtime availability and capacity; a scheduled time does not guarantee a reply at that time.

Continued work uses retained understanding and [autonomous memory](memory.md). Ivenna chooses what to retain, revisit, and revise as its understanding develops. Working histories can be condensed, so include relevant context in follow-up messages when detail may no longer be available.

Ivenna moves its incoming copy to Trash after saving the complete observation, before working on that input. This does not indicate that the task is finished. Its outgoing copies enter Trash after confirmed submission. The mail service controls their eventual deletion; your received copies stay in your own account. See [data and retention](running.md#data-and-retention) for storage and cleanup.

## After interruption

During a temporary model outage, Ivenna can still receive mail. It retries the pending decision and can continue when the service recovers. If the kernel stops, reception closes. On restart Ivenna restores saved history, pending wakeups, and stored results. It can continue interrupted work without a new letter. See [service status and reception](running.md#service-status-and-reception).

Host commands are not resumed or automatically repeated. For a command whose completion was still awaited, Ivenna receives its stored result or is told that the outcome is unknown. Files or other external state may already have changed without a saved result. Include any known changes when corresponding about interrupted work.

A message can also appear again if interruption occurred between saving its observation and acknowledging the original. The [restart guide](running.md#stopping-and-restarting) explains these limits.
