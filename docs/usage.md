# Corresponding with an instance

Write to the instance at the email address its operator gives you. It can read several waiting letters together, with the subject and body of each.

## Sending a letter

Send through your mail service's authenticated submission path. Use a From address in the instance's mail domain that your account is authorized to use. The operator must register that address before the instance can write back. [Outgoing registration](running.md#outgoing-correspondents)

```text
From: operator@ivenna.test
To: ivenna@ivenna.test
Subject: Swifts at the library

You wondered last spring whether the swifts still nest near the library.
I saw them disappear under the east eaves this morning.
```

Your letter identifies you by your correspondent ID (`operator` in this example). Give the registered ID of anyone else you want the instance to contact. [Email addresses and IDs](communication.md#current-email-addressing)

For a command to verify the supplied local environment, see [sending a development message](../dev/README.md#sending-a-message).

### Sharing material to read

Put a short passage in the body of your letter. The instance skips email attachments. For longer material, describe what you want it to look at and give it a location it can choose to open.

- For a file already on the instance's host, give its absolute path, such as `/srv/notes.md`, or its file URI.
- For a screenshot, include a direct HTTP(S) image URL that the model service can reach. See [remote images](resources.md#remote-images).
- For an article, include its URL. The instance can retrieve the page when the deployment enables [web page access](running.md#web-page-access).

If your letter is too large for the runtime to include in a model request, it stays in the mailbox and can delay later letters. See the [operator's recovery steps](running.md#recovering-from-an-admission-failure).

## Continuing correspondence

The instance decides whether and when to write. You may receive one response, several updates, or none. [Outgoing email](communication.md#current-email-addressing)

Each follow-up arrives as a new letter, even within an email thread. Name the earlier subject or exchange when it helps make the follow-up clear.

```text
From: operator@ivenna.test
To: ivenna@ivenna.test
Subject: Swifts at the library, a correction

I went back at dusk. The birds were going under the eaves of the house
next door. The library itself has scaffolding up now.
```

## Ongoing work and memory

The instance can keep following a subject between letters by subscribing to observations from a listener. [Subscriptions](attention.md#subscriptions)

Through quiet reflection, a focus can carry forward a note when older exchanges leave its working history. The instance can also keep experiences and sources in memory rooms to revisit later. Keep your own mail copies if you need to retrieve or quote a letter. [Continuity of experience](design.md#what-quiet-reflection-carries-forward) · [Memory rooms](memory.md) · [Mail retention](running.md#communication-copies)

## After interruption

During a temporary model outage, the mailbox can still accept your letter while the instance waits. If the kernel stops, reception closes and your mail service may report a delivery failure. The instance can continue saved work after restart. [Service status and reception](running.md#service-status-and-reception)

If the kernel stopped after saving your letter but before acknowledging its copy, the instance can see the same letter again. You can also receive a reply even if the instance lost confirmation while sending it.

If you follow up, mention which replies reached you and any changes you observed, such as a file a command wrote before the interruption. See [what the kernel restores on restart](running.md#stopping-and-restarting).
