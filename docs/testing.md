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

The root test step runs the registered library and application suites. Run `zig build test` from `apps/ivenna` for the CLI suite. Library roots include internal test files through `test` blocks in `src/root.zig`. To add a package suite, register it in the root build and dependency manifest. See the [root build](../build.zig), [application build](../apps/ivenna/build.zig), and [dependency manifest](../build.zig.zon).

For the [memory protocol tests](../apps/memory/tests.nu), install Nushell at the version used in the memory [Containerfile](../apps/memory/Containerfile). These tests also use the standard `ln` command:

```sh
nu --no-config-file --no-history apps/memory/tests.nu
```

The script uses Nushell's standard assertions, sends JSON requests directly to the handler in temporary workspaces, and removes those workspaces afterward. It uses no configuration or data from the development instance. Keep CI's Nushell version aligned with the Containerfile when upgrading it.

## Automated coverage

The [CI workflow](../.github/workflows/ci.yml) invokes these checks on Linux. The suites use local fixtures and run without deployed services or model credentials.

### Test boundaries

- **Command line and channels.** Process tests exercise help and argument errors without deployment settings, subscription publication with the kernel stopped, and single-read timeouts. Socket tests verify that a handoff consumes one waiting request. Pipeline tests cover a reader closing after one flushed message and during a blocked write. [CLI tests](../apps/ivenna/src/cli_test.zig)
- **Instance state.** Two subscription connections exercise cursor conflicts, retries after acknowledgement, and whether queued reports retain their destination after withdrawal. [Subscription store](../packages/instance_state/src/subscriptions.zig)
- **Focus execution.** Fixtures exercise startup, routing by destination kind, and report admission after a failed or unconfirmed checkpoint. The wakeup test follows the original scheduled time through publication, restart, and admission. [Kernel tests](../packages/agent/src/kernel.zig) · [Session registry tests](../packages/agent/src/sessions.zig)
- **Handovers and working history.** Tests check that sampled registrations and their descriptions accompany the summary. The persistence test appends to history that includes an earlier handover format. [Context tests](../packages/agent/src/context.zig) · [History tests](../packages/agent/src/history.zig)
- **Mail.** A local JMAP server verifies recipient lookup before draft creation and the address stored on the draft. Connection failures exercise mailbox read recovery, uncertain submission, and confirmation of callback and history writes. [Email transport](../packages/email/src/email_transport.zig) · [Email tests](../packages/email/src/root.zig)
- **Model transport and resources.** HTTP fixtures compare measured request sizes with encoded bodies, exercise file upload outcomes, and verify that two focuses can read one page snapshot from a single fetch. [Responses tests](../packages/responses/src/provider_test.zig) · [Web reader tests](../packages/resources/src/web_test.zig)

The email, Responses, and web reader tests check that canceling a stalled HTTP exchange closes the connection. The local server checks for further request bytes and open connections. Measuring bytes received over TLS requires exercising the request writer against a local HTTPS server. [Local server](../tests/http.zig) · [Model transport](architecture.md#model-transport)

## Validating with running services

Use the [local environment](../dev/README.md) to validate restart and communication through the configured services. Replay representative work with the same model and starting history when comparing changes to model context.

Use the [channel walkthrough](../dev/README.md#trying-a-channel) to check send feedback, delivery of successive messages to one receiver, and stream exit on channel close through the running application.

### Evaluating compaction

Use the focus's saved epoch to identify a committed handover. Check stderr for interruptions when compaction does not commit. See [context budgets](running.md#context-budgets) and [persistent working history](architecture.md#persistent-working-history).

Compare the sample with the channel and subscription registrations active around its `observed_at` time and with the original scheduled times of pending wakeups. Check that later callbacks and reports reach the focus that arranged them, and see whether its subsequent work uses the relevant commitments, corrections, and evidence. See [sampled state](input.md#sampled-state).

### Evaluating context disclosure

Compare cases where the information could inform the next decision with cases where it is incidental. Observe whether the focus uses a relevant reference or turns to unrelated work. Record request size separately. See [context and continuity](design.md#context-and-continuity).
