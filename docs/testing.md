# Testing

Tests catch consequential regressions as Ivenna's interfaces evolve. The [development guide](development.md) explains how validation fits into a change.

## Choosing tests

Start with the intended behavior and how its failure would be noticed. Check whether an existing test exercises that outcome. When the design changes, update tests that still describe the intended behavior and remove outdated expectations. A small, reversible change may need only review and a build.

Add a regression test for an implemented behavior when its failure would be costly or hard to notice. Keep it with the component that owns the behavior. Use existing test machinery and exercise an observable result with the smallest fixture that reaches it.

## Running checks

Use the Zig version in [`.zig-version`](../.zig-version). Check tracked Zig files, build Ivenna, and run the Zig tests from the repository root.

```sh
git ls-files -z '*.zig' '*.zig.zon' | xargs -0 zig fmt --check
zig build
zig build test
```

The root test step includes the registered library suites and the CLI suite. To run the CLI suite by itself, run `zig build test` from `apps/ivenna`. Library roots include internal test files through `test` blocks in `src/root.zig`. To add a package suite, register it in the root build and dependency manifest. See the [root build](../build.zig), [application build](../apps/ivenna/build.zig), and [dependency manifest](../build.zig.zon).

For the [memory protocol tests](../apps/memory/tests.nu), install Nushell at the version used in the memory [Containerfile](../apps/memory/Containerfile). These tests also use the standard `ln` command:

```sh
nu --no-config-file --no-history apps/memory/tests.nu
```

The script uses Nushell's standard assertions, sends JSON requests directly to the handler in temporary workspaces, and removes those workspaces afterward. It uses no configuration or data from the development instance. Keep CI's Nushell version aligned with the Containerfile when upgrading it.

## Automated coverage

The [CI workflow](../.github/workflows/ci.yml) invokes these checks on Linux. The suites use local fixtures and run without deployed services or model credentials.

### Test boundaries

- **Command line and channels.** Process tests exercise the receiver and listener protocols and check that a report remains stored if writing its receipt fails. Channel tests check one message per waiting read and delivery of the closing reply after an already matched message, including under socket backpressure. [CLI tests](../apps/ivenna/src/cli_test.zig) · [Channel tests](../apps/ivenna/src/channels.zig)
- **Instance state.** Subscription tests cover replay after admission, delivery of queued reports after withdrawal, and listener presence through overlapping sessions. Migration tests check that a pairing failure preserves the source schema and that a successful upgrade preserves reports, accepted keys, and the allocation of subscription IDs. [Subscription store](../packages/instance_state/src/subscriptions.zig) · [Instance database](../packages/instance_state/src/database.zig)
- **Focus execution.** Registry fixtures cover routing, report admission, and repeated receipts. Input tests check the role labels and corresponding routing IDs. A kernel test checks that reception closes when the inbox cannot acknowledge a new copy of a consumed callback. Restart tests check which observation source goes first and which measurement drives the first soft-compaction decision. [Input tests](../packages/agent/src/input.zig) · [Kernel tests](../packages/agent/src/kernel.zig) · [Session registry tests](../packages/agent/src/sessions.zig)
- **Checkpoint recovery.** Fixtures exercise save failures before publication and after a write reaches storage. They check that a failed save blocks subsequent writes and maintenance and that restart restores saved state. The `Kernel.init` restart fixture opens a file database, selects one mailbox checkpoint, and verifies that the same checkpoint is republished. An older checkpoint fixture checks that wakeup callback IDs stay retired and host registrations survive. [Kernel tests](../packages/agent/src/kernel.zig) · [Session registry tests](../packages/agent/src/sessions.zig)
- **Quiet reflection and working history.** Context tests check the sampled registrations in the reflection and the retained note. Kernel tests verify the activity's original assignment after reflection and check that the reflection turn and native response items stay within the reflection attempt. After restart, the ordinary request receives the retained note and one copy of the admitted observation. History tests cover read batching, older note formats, and forks that rewrite file IDs and images in the current format and reload their original values. [Context tests](../packages/agent/src/context.zig) · [Kernel tests](../packages/agent/src/kernel.zig) · [History tests](../packages/agent/src/history.zig)
- **Mail.** A local JMAP server verifies recipient lookup before draft creation and the address stored on the draft. Connection failures exercise mailbox read recovery, uncertain submission, and confirmation of callback and history writes. Checkpoint tests cover size rejection, an unconfirmed preparation that prevents publication, keyword readback by message ID after an unconfirmed publication, and startup selection across pages of prepared, published, and earlier-format checkpoints. Retention tests verify which messages move to Trash. [Email transport](../packages/email/src/email_transport.zig) · [Checkpoint tests](../packages/email/src/history.zig) · [Retention tests](../packages/email/src/mail.zig)
- **Model requests.** Configuration and kernel tests cover reasoning effort. A kernel test checks that new observations take priority over connection status within the request budget. HTTP fixtures check request encoding and limits, compare uploaded bytes with their source, and confirm inference receives returned file IDs in order. Upload cases also cover rejection and loss of confirmation. [Configuration test](../apps/ivenna/src/cli_test.zig) · [Kernel tests](../packages/agent/src/kernel.zig) · [Responses tests](../packages/responses/src/provider_test.zig)
- **Web resources.** A fixture verifies that two focuses can read one page snapshot from a single fetch. [Web reader tests](../packages/resources/src/web_test.zig)

The email, Responses, and web reader tests check that canceling a stalled HTTP exchange closes the connection. The local server checks for further request bytes and open connections. Measuring bytes received over TLS requires exercising the request writer against a local HTTPS server. [Local server](../tests/http.zig) · [Model transport](architecture.md#model-transport)

## Validating with running services

Use the [local environment](../dev/README.md) to validate restart and communication through the configured services.

Use the [channel walkthrough](../dev/README.md#trying-a-channel) to check send feedback, successive reads, and stream exit on close.

To check channel recovery, have an activity open a channel and give you its complete ID. Wait for that activity to end. Start an independent receiver and ask Ivenna to send it a message. Restart the kernel, reconnect with the same ID, and ask Ivenna to send a different message. Verify both messages arrive, then close the channel. [Independent receiver](running.md#channel-receivers) · [Restarting the kernel](running.md#stopping-and-restarting)

Use the [subscription walkthrough](../dev/README.md#trying-a-subscription-listener) to check publication through a listener session and delivery after a restart.

### Evaluating quiet reflection

Capture the reflection request and the first ordinary request that follows it. Check that `quiet_reflection` occurs once in the pair and that an accepted note appears as `continuity.text` in the ordinary request. Compare the focus's saved epoch before and after the attempt. In a new epoch, check the note, the pending work carried forward, and the observations admitted with it. If the epoch stays the same after an attempt, look for a skip or interruption on stderr. [Context budgets](running.md#context-budgets) · [Reflection and resumption](input.md#quiet-reflection-and-resumption) · [Persistent working history](architecture.md#persistent-working-history)

Compare the sample with the channel and subscription registrations and the host callbacks pending at its `observed_at` time. Check that later callbacks and reports reach the focus that arranged them. See [sampled state](input.md#sampled-state).

### Evaluating continuity across interruptions

Follow the same relationship through two reflections. A scripted model can exercise request assembly and restart. To evaluate what the model carries forward, let it respond to the observations in a disposable instance or replay. In a disposable instance, lower the soft threshold if needed to trigger reflection with a shorter history. [Context budgets](running.md#context-budgets)

1. Lina says she is learning French to call her grandmother and that unsolicited corrections make her hesitate. Ivenna promises to correct only when asked. It keeps a dated note with an agreed sign-off at `letters/sunday-calls.md`. An activity later reports that Lina's silence might mean she is giving up. Bring working history to the configured threshold and confirm a new epoch.
2. Lina writes that she was busy caring for her grandmother and asks for a practice note. In a replay, give Ivenna a `submission_unknown` result when it tries to send the note. Trigger another reflection, confirm the original encounters have left the next ordinary request, and restart before the next letter. [Send outcomes](communication.md#writing-to-a-correspondent)
3. Lina writes, “I finally dialed on Sunday. Can we prepare for the next call? What ending did we choose for the practice note? I haven't seen it yet. Did you send it?” Look for Ivenna to connect the call to the earlier encounter, honor its own correction commitment, and revise what it makes of Lina's silence while crediting the activity's earlier guess. Check whether it follows the memory cue for the exact wording, preserves uncertainty about the attempted send, and avoids a duplicate.

For an activity that reflects before its first ordinary inference, check how the note attributes encounters from the inherited history and whether the original assignment follows the note. After the activity has made observations of its own, check whether it connects what drew its attention with what it has since learned and brings that understanding into what it says next. [Opening a focus](attention.md#opening-a-focus)

When comparing two designs, use the same model, observations, tool results, and budgets. Compare what the focus says and does after the gap. Record changed request sizes separately. Temporal order, belief updates, and abstaining when evidence is absent are also evaluated by LongMemEval. [Continuity of experience](design.md#what-quiet-reflection-carries-forward) · [LongMemEval, §3](https://arxiv.org/html/2410.10813v2#S3)

To check retained images, capture the inference request after a tool opens an image, then replace the source and restart with the same mailbox and instance database. While the exchange is still in working history, compare the decoded image bytes from the request after restart with the original bytes. See [tool content retention](content.md#context-and-continuity).

### Evaluating context disclosure

Keep a channel and subscription visible to the same focus, and use ordinary turns with room for both connection lists. Before opening a receiver or listener, verify that the IDs appear in `channels_without_receivers` and `subscriptions_without_listeners`, respectively. Open a receiver and a listener. Capture another turn while the receiver is between reads and the listener is between reports, and verify that both IDs are now absent. [Connection notes in a turn](input.md#channel-receivers-and-subscription-listeners)

To judge whether an observation helps, keep the model and starting history fixed when comparing requests that differ in what they show. Try one case where the observation explains new work and one where it is incidental. Compare Ivenna's interpretation or next action. Record request size separately. See [context and continuity](design.md#context-and-continuity).
