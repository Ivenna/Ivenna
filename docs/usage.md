# Corresponding with Ivenna

Send ordinary mail to `MAIL_ADDRESS` after [starting the kernel](running.md#starting-the-kernel). Ivenna's core receives new correspondence and can answer directly or hand work to a separate session. That session uses tools and replies in the same mail thread, while the core remains available for other correspondence.

## Sending a request

Use the operator account configured during [mail setup](running.md#configuring-local-mail), or another account that can reach Ivenna. Give the request a useful subject and put the task and relevant context in its body.

The following example requires `curl` and submits through the supplied local service's authenticated SMTP endpoint. Run it from a second terminal at the repository root:

```sh
set -a
. ./.env
set +a
curl --url "smtp://127.0.0.1:${MAIL_SMTP_PORT:-2525}" \
  --user "$OPERATOR_MAIL_ADDRESS:$OPERATOR_MAIL_PASSWORD" \
  --mail-from "$OPERATOR_MAIL_ADDRESS" \
  --mail-rcpt "$MAIL_ADDRESS" \
  --upload-file - <<EOF
From: $OPERATOR_MAIL_ADDRESS
To: $MAIL_ADDRESS
Subject: French practice
Message-ID: <french-practice-$(date +%s)@ivenna.test>

Please remember that I am learning French and propose a practice plan.
EOF
```

Read replies through a JMAP-capable client or mail API using the operator account and the service's JMAP session URL. The [configuration reference](running.md#changing-configuration) lists that endpoint and its default. For another service, use its submission and client settings.

SMTP acceptance means the service accepted the request for delivery. Allow time for Ivenna to process it, including any tool work. A reply can provide a result, ask for clarification, or describe unfinished work.

Plain-text bodies are preferred; HTML-only letters supply their HTML source. Ivenna receives the subject and body as text. Longer content includes an excerpt and a reference to the full material, which it can retrieve when needed. The deployment keeps these [source files](running.md#local-data) for inspection. Mail attachment intake remains a placeholder; host and memory tools can work with [text and images](content.md) in their workspaces.

## Continuing a conversation

Reply to Ivenna's letter in your mail client. A programmatic reply should keep the thread's subject, put the `Message-ID` of the Ivenna letter being answered in `In-Reply-To`, and append that identifier to its existing `References` chain. Replace the illustrative identifiers below with those from the correspondence:

```text
To: ivenna@ivenna.test
Subject: Re: French practice
Message-ID: <french-practice-2@example.local>
In-Reply-To: <ivenna-reply-being-answered@example.local>
References: <french-practice-1@example.local> <ivenna-reply-being-answered@example.local>

Use Tuesday and Saturday, and keep each session to 20 minutes.
```

Related input queues with the session handling that thread while its current work continues. Independent threads can run concurrently. Reusing a subject alone does not reliably establish a reply relationship.

Reply in the same thread even after a clarification question or a gap in the work. Ivenna can continue from the thread's handover and recent correspondence after releasing its old working context. Older letters can remain in Inbox or be archived.

## Managing work through mail

Use normal folders, flags, and replies in Ivenna's account to manage attention:

| Action or state | Effect |
| --- | --- |
| Unread letter in Inbox | Input eligible for work |
| Reply in the existing thread | Another input turn for that conversation |
| Flagged input (`$flagged`) | Priority when the runtime accepts and schedules it |
| Read input (`$seen`) | Excluded from intake; Ivenna sets this after handling a letter |
| Answered input (`$answered`) | Ivenna submitted a reply for delivery |
| Active input removed from Inbox | Withdraw further work at the next complete model/tool boundary |
| Archive finished correspondence | Keep it for reference; later replies can still continue the thread |

Use the operator account for ordinary correspondence. A client marking letters read in Ivenna's account changes which input is eligible; it is separate from reading the replies in the operator account.

Ordinary self-addressed input follows the same intake and withdrawal rules. Ivenna's saved handover records are excluded from task intake.

To withdraw ongoing work, move its input letter out of Ivenna's Inbox. The current model response and its tool batch finish before withdrawal takes effect. This stops further work on that letter; internal helper work that has already started can continue. Completed commands, memory changes, and submitted replies retain their effects. A related follow-up can describe the known outcome and provide the next direction.

Archive and later delete correspondence to manage mailbox capacity. This is separate from releasing working context. Automatic retention policy is not implemented; source files and host logs also need their own retention and cleanup.

## Work sessions and handovers

Ivenna decides when to hand work to another session or ask an internal helper for findings. The session responsible for your thread replies directly; it does not need another core turn to deliver its answer. The [architecture guide](architecture.md#forks-and-work-ownership) explains how these sessions share context and coordinate work.

After a work session finishes processing a thread's input, Ivenna saves a handover summarizing its understanding. It can release the working context once no queued input or child session remains. Processed source letters are marked read and stay in their existing folders.

Handovers are readable self-addressed state records saved directly in Archive. Ivenna associates them with work independently of the external reply chain; reply to the ordinary correspondence to continue it. Saving a note does not archive source letters. Ivenna also records handovers when shortening a model context.

If a handover cannot be saved after a reply was submitted, Ivenna logs the failure and keeps the working context. Retain handovers, source correspondence, and referenced files when preserving continuity. See [bounded model context](architecture.md#bounded-model-context) for the summary and reconstruction limits.

## After interruption

Restart with the same mailbox, artifacts, and memory workspace. Ivenna rebuilds its understanding from handovers and recent correspondence, takes up unread Inbox input, and can continue existing threads. Interrupted model requests and tool calls do not resume from their previous execution point.

An interrupted operation may already have changed files, memory, or mail. Inspect those effects before repeating uncertain work. A follow-up letter can explain what is known and ask Ivenna to continue. Execution failure pauses that conversation and retains its input while suppressing repeated automatic attempts in the current process; new related input can supply direction.

See [startup and interruption](architecture.md#startup-and-interruption) for the runtime contract.
