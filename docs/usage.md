# Corresponding with Ivenna

Write to Ivenna at the email address its operator gives you. Ivenna can read several waiting letters together, with the subject and body of each.

## Sending a letter

Send through your mail service's authenticated submission path. Use a From address in Ivenna's mail domain that your account is authorized to use. For Ivenna to be able to write back, the operator must register that address for outgoing mail. See [outgoing registration](running.md#outgoing-correspondents).

```text
From: operator@ivenna.test
To: ivenna@ivenna.test
Subject: Swifts at the library

You wondered last spring whether the swifts still nest near the library.
I saw them disappear under the east eaves this morning.
```

Your letter identifies you by your correspondent ID (`operator` in this example). To ask Ivenna to contact someone else, give their registered ID. See [email addresses and IDs](communication.md#current-email-addressing).

For a command to verify the supplied local environment, see [sending a development message](../dev/README.md#sending-a-message).

### Sharing material to read

Put a short passage in the body of your letter. Ivenna skips email attachments. For longer material, describe what you want Ivenna to look at and give it a location it can choose to open.

- For a file already on Ivenna's host, give its absolute path, such as `/srv/notes.md`, or its file URI.
- For a screenshot, include a direct HTTP(S) image URL that the model service can reach. See [remote images](resources.md#remote-images).
- For an article, include its URL. Ivenna can retrieve the page when the deployment enables [web page access](running.md#web-page-access).

If your letter is too large for the runtime to include in a model request, it stays in the mailbox and can delay later letters. See the [operator's recovery steps](running.md#recovering-from-an-admission-failure).

## Continuing correspondence

Ivenna decides whether and when to write. You may receive one response, several updates, or none. See [how Ivenna sends email](communication.md#current-email-addressing).

Ivenna sees each follow-up as a new letter, even within an email thread. Name the earlier subject or exchange when it helps make the follow-up clear.

```text
From: operator@ivenna.test
To: ivenna@ivenna.test
Subject: Swifts at the library, a correction

I went back at dusk. The birds were going under the eaves of the house
next door. The library itself has scaffolding up now.
```

## Ongoing work and memory

Ivenna can keep following a subject between letters by subscribing to observations from a listener. See [subscriptions](attention.md#subscriptions).

Ivenna can condense its working history and decide what to keep in memory. Keep your own mail copies if you need to retrieve or quote a letter later. See [autonomous memory](memory.md) and [mail retention](running.md#communication-copies).

## After interruption

During a temporary model outage, the mailbox can still accept your letter while Ivenna waits. If the kernel stops, reception closes and your mail service may report a delivery failure. Ivenna can continue saved work after restart. See [service status and reception](running.md#service-status-and-reception).

If the kernel stopped after saving your letter but before acknowledging its copy, Ivenna can see the same letter again. You can also receive a reply even if Ivenna lost confirmation while sending it.

If you follow up, mention which replies reached you and any changes you observed, such as a file a command wrote before the interruption. See [what the kernel restores on restart](running.md#stopping-and-restarting).
