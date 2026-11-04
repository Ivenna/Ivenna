# Corresponding with Ivenna

Send ordinary mail to `MAIL_ADDRESS` after [starting the kernel](running.md#starting-the-kernel). The kernel receives the letter, prepares model input, runs tools as needed, and submits a reply. A mail thread carries a work conversation; each incoming letter starts a turn that can require several model and tool rounds.

## Sending a request

Use the operator account configured during [mail setup](running.md#configuring-local-mail), or another account that can reach Ivenna. Give the request a useful subject and put the task and relevant context in its body.

For the supplied local service, submit through authenticated SMTP from a second terminal at the repository root:

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

SMTP acceptance means the service accepted the request for delivery. Allow time for Ivenna to process it. Tool results feed further model rounds until the model produces a response with no tool calls. The reply can provide a result, ask for clarification, or describe unfinished work. Intermediate assistant text remains in the working transcript.

Plain-text bodies are preferred; HTML-only letters supply their HTML source. The model receives a bounded excerpt and a reference to the full body under `DATA_DIR/mail/`, which host tools can inspect. Mail attachment intake remains a placeholder; host and memory tools can work with [text and images](content.md) in their workspaces.

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

Related input queues in its conversation while the current turn continues. Independent threads can run concurrently. Reusing a subject alone does not reliably establish a reply relationship.

When a turn ends and no input remains queued, Ivenna records a handover and archives its processed input. The handover preserves the understanding needed to reopen the thread in a dedicated working context. The core perspective continues while these work conversations come and go.

A conversation can be archived after a clarification question while its broader task remains open. Reply in the same thread to supply the answer or continue the work; the old letter can stay archived.

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
| Processed input moved to Archive by Ivenna | The turn ended and a handover was saved |

Use the operator account for ordinary correspondence. A client marking letters read in Ivenna's account changes which input is eligible; it is separate from reading the replies in the operator account.

To withdraw ongoing work, move its input letter out of Ivenna's Inbox. The current model response and its tool batch finish before withdrawal takes effect. Completed commands, memory changes, and submitted replies retain their effects. A related follow-up can describe the known outcome and provide the next direction.

After archiving, Ivenna releases the branch context or the conversation's temporary use of the core if no input remains queued. It archives explicit processed letters, so newly arriving input stays available. Coordinated deletion of archived correspondence and its local artifacts is not implemented. Ordinary mail clients can still delete letters; local body files and host logs need separate cleanup.

## Reports and handovers

While the core is occupied, independent work can use a branch of its most recent complete context. The runtime packages the branch's final text with its work subject, source reference, and session identity in a self-addressed report. The core receives reports at complete execution boundaries.

Handovers summarize working understanding when context is shortened and when a conversation is archived. They retain the subject and native reply headers so they remain with the original thread in Archive. Reports enter Inbox. The runtime writes these readable letters directly through the mail API; model reasoning and individual tool calls remain in runtime history.

If report delivery or archival fails after a reply was submitted, Ivenna logs the failure and keeps the conversation's context. Later input can continue from that understanding; the failed operation has no automatic retry. Retain handovers, source correspondence, and referenced files when preserving continuity. The [architecture guide](architecture.md#bounded-model-context) explains the context bounds and reconstruction process.

## After interruption

Restart with the same mailbox, artifacts, and memory workspace. Ivenna rebuilds its core understanding from handover and bounded recent correspondence, takes up waiting input, and can reopen archived threads. Suspended model requests and individual tool results belong to the previous process's working history.

An interrupted operation may already have changed files, memory, or mail. Inspect those effects before repeating uncertain work. A follow-up letter can explain what is known and ask Ivenna to continue. Execution failure pauses that conversation and retains its input while suppressing repeated automatic attempts in the current process; new related input can supply direction.

See [startup and interruption](architecture.md#startup-and-interruption) for the runtime contract.
