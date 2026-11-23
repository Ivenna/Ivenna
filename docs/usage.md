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

Ivenna decides whether and when to write. You may receive one response, several updates, or none. Read its messages in your mail client under the subject `Ivenna`.

For a command to verify the supplied local environment, see [sending a development message](../dev/README.md#sending-a-message).

### Sharing material to read

Put a short passage directly in the body of your letter. Ivenna reads the message body and skips attachments. See [incoming email text](communication.md#incoming-email-text) for how it handles plain text and HTML.

- For a file that Ivenna can read on its host, give an absolute file URI such as `file:///srv/notes.md`.
- For a screenshot, include a direct HTTP(S) link that Ivenna's model service can open.
- For an article, include its URL. Ivenna can send it to a page reader when the deployment enables [web page access](running.md#web-page-access).

A link can also help keep a long letter within the model's request budget. If the letter and its required context still exceed that budget after compaction, the letter stays in the mailbox and delays later correspondence. See [resolving an admission failure](running.md#recovering-from-an-admission-failure).

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

Ivenna can pursue work between your messages and may read several waiting letters together. If you ask it to follow a project's releases, a listener can bring a new version to its attention without another letter from you. The core can also schedule a wakeup, and an activity can resume when its host command finishes.

The core sees activity updates with its next ordinary input. An activity's ending calls for its attention. Ivenna decides whether and when to write back. See [how focuses coordinate](attention.md).

Continued work uses retained understanding and [autonomous memory](memory.md). Ivenna chooses what to retain, revisit, and revise as its understanding develops. Include relevant context when following up, since Ivenna can condense its working history. Keep your own copy if you need the exact wording after [Ivenna's mail copies expire](running.md#communication-copies).

## After interruption

During a temporary model outage, Ivenna can still receive mail. It retries the pending decision and can continue when the service recovers. If the kernel stops, reception closes. On restart Ivenna restores saved history, pending wakeups, and stored results. It can continue interrupted work without a new letter. See [service status and reception](running.md#service-status-and-reception).

If the kernel stopped after saving your letter but before acknowledging its copy, Ivenna can see the same letter again. You can also receive a reply even if Ivenna lost confirmation while sending it.

The kernel does not resume or replay host commands. Ivenna receives a stored completion it was waiting for, or learns that the outcome is unknown. If you follow up, mention which replies reached you and any changes you observed, such as a file the command wrote before the interruption. See [stopping and restarting](running.md#stopping-and-restarting).
