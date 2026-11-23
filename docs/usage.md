# Corresponding with Ivenna

Send your letter by email while reception is open. If reception is closed, your mail service may report a delivery failure. See [service status and reception](running.md#service-status-and-reception).

## Sending a request

Use an account in the same domain as Ivenna. Send through your mail service's authenticated submission path, using a From address authorized for that account.

```text
From: operator@ivenna.test
To: ivenna@ivenna.test
Subject: French practice

Please remember that I am learning French and propose a practice plan.
```

Ivenna sees your correspondent ID (`operator` here), the subject, and the body. Each From address must map to a supported ID. To ask Ivenna to contact someone else, give their ID in the letter. See [email addressing](communication.md#current-email-addressing).

For a command to verify the supplied local environment, see [sending a development message](../dev/README.md#sending-a-message).

### Sharing material to read

Put a short passage in the body of your letter. Ivenna skips email attachments. For longer material, describe what you want Ivenna to look at and give it a location it can choose to open.

- For a file already on Ivenna's host, give its absolute path, such as `/srv/notes.md`, or its file URI.
- For a screenshot, include a direct HTTP(S) link that Ivenna's model service can open.
- For an article, include its URL. Ivenna can send it to a page reader when the deployment enables [web page access](running.md#web-page-access).

If the letter and its required context still exceed the model's request budget after history compaction, the letter stays in the mailbox and can delay later mail. See [recovering from an admission failure](running.md#recovering-from-an-admission-failure).

## Continuing correspondence

Ivenna decides whether and when to write. You may receive one response, several updates, or none. Its messages arrive under the subject `Ivenna`.

Each follow-up reaches the core as a new observation, even within an email thread. Identify the earlier request and say what has changed.

```text
From: operator@ivenna.test
To: ivenna@ivenna.test
Subject: French practice schedule

About the French practice plan: use Tuesday and Saturday, and keep each
session to 20 minutes. Please retain the vocabulary goals we agreed on.
```

## Ongoing work and memory

Ivenna can pursue work between your messages and may read several waiting letters together. If you ask it to follow a project's releases, a listener can bring a new version to its attention without another letter from you. See [how focuses coordinate and resume work](attention.md).

Continued work uses retained understanding and [autonomous memory](memory.md). Ivenna chooses what to retain, revisit, and revise as its understanding develops. Include relevant context when following up, since Ivenna can condense its working history. Keep your own copy if you need the exact wording after [Ivenna's mail copies expire](running.md#communication-copies).

## After interruption

During a temporary model outage, Ivenna can still receive mail. It retries the pending decision and can continue when the service recovers. If the kernel stops, reception closes. On restart Ivenna restores saved history, pending wakeups, and stored results. It can continue interrupted work without a new letter. See [service status and reception](running.md#service-status-and-reception).

If the kernel stopped after saving your letter but before acknowledging its copy, Ivenna can see the same letter again. You can also receive a reply even if Ivenna lost confirmation while sending it.

The kernel does not resume or replay host commands. Ivenna receives a stored completion it was waiting for, or learns that the outcome is unknown. If you follow up, mention which replies reached you and any changes you observed, such as a file the command wrote before the interruption. See [stopping and restarting](running.md#stopping-and-restarting).
