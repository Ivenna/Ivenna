# Testing

Tests support Ivenna's exploratory development by catching consequential regressions while leaving interfaces and implementation free to evolve. Keep their setup, execution, and maintenance costs small enough to support routine iteration. The [development guide](development.md) sets the broader change conventions.

## Choosing tests

Choose checks from the intended behavior and the consequences of failure. Add a focused regression test when a failure would be costly or hard to notice during ordinary development. Review existing tests for affected behavior and revise or remove expectations when the design changes.

Choose the smallest check that gives useful evidence at the boundary owning the behavior. Prefer observable outcomes over internal layout, exact prompt wording, or incidental serialization. A small, reversible change may need only review and a build. Judge a test by the failure it can expose and the maintenance it adds.

During development, do not write tests in advance or introduce test frameworks. Keep fixtures and setup limited to what the outcome requires. Keep tests with the component that owns the behavior, and adjust their placement as those responsibilities change.

## Running checks

Use the Zig version in [`.zig-version`](../.zig-version). Check tracked Zig files, build Ivenna, and run the Zig tests from the repository root.

```sh
git ls-files -z '*.zig' '*.zig.zon' | xargs -0 zig fmt --check
zig build
zig build test
```

The root test step runs the registered library and application suites. Run `zig build test` from `apps/ivenna` to run just the CLI process tests. Library roots include internal test files through `test` blocks in `src/root.zig`. To add a package suite, register it in the root build and dependency manifest. See the [root build](../build.zig), [application build](../apps/ivenna/build.zig), and [dependency manifest](../build.zig.zon).

For the [memory protocol tests](../apps/memory/tests.nu), install Nushell at the version used in the memory [Containerfile](../apps/memory/Containerfile). These tests also use the standard `ln` command:

```sh
nu --no-config-file --no-history apps/memory/tests.nu
```

The script uses Nushell's standard assertions, sends JSON requests directly to the handler in temporary workspaces, and removes those workspaces afterward. It uses no configuration or data from the development instance. Keep CI's Nushell version aligned with the Containerfile when upgrading it.

## Automation and validation limits

The [CI workflow](../.github/workflows/ci.yml) invokes these checks on Linux. The suites use local fixtures and run without deployed services or model credentials.

### Test boundaries

- **Command line.** Tests run `ivenna` as a separate process to check help and argument errors before configuration, listener receipts, and message input. They exercise immediate and timed reads, streamed output before end of input, and exit after a downstream reader takes one message. [CLI process tests](../apps/ivenna/src/cli_test.zig)
- **Instance state.** Two subscription connections exercise cursor conflicts, retries after acknowledgement, and whether queued reports retain their destination after withdrawal. [Subscription store](../packages/instance_state/src/subscriptions.zig)
- **Focus execution.** Fixtures exercise startup with changed registrations, routing by destination kind, and tool exchanges and references carried through handovers. They also check that each report is admitted once after a checkpoint failure or lost confirmation. [Kernel tests](../packages/agent/src/kernel.zig) · [Context tests](../packages/agent/src/context.zig) · [Session registry tests](../packages/agent/src/sessions.zig)
- **Working history.** The persistence test loads a handover with retired fields, appends a new entry, and reloads the saved history. [History tests](../packages/agent/src/history.zig)
- **Host execution.** Channel tests exercise send outcomes when a message is too long, the previous message is unread, or the command has exited. They also check that closing a channel lets its command read the pending message and keep running. [Host tests](../packages/host/src/root.zig) · [Command input tests](../packages/host/src/command_input.zig)
- **Mail.** A local JMAP server verifies recipient lookup before draft creation and the address stored on the draft. Connection failures exercise mailbox read recovery, uncertain submission, and confirmation of callback and history writes. [Email transport](../packages/email/src/email_transport.zig) · [Email tests](../packages/email/src/root.zig)
- **Model transport and resources.** HTTP fixtures compare measured request sizes with encoded bodies, exercise file upload outcomes, and verify that two focuses can read one page snapshot from a single fetch. [Responses tests](../packages/responses/src/provider_test.zig) · [Web reader tests](../packages/resources/src/web_test.zig)

The email, Responses, and web reader tests check that canceling a stalled HTTP exchange closes the connection. The local server checks for further request bytes and open connections. Measuring bytes received over TLS requires exercising the request writer against a local HTTPS server. [Local server](../tests/http.zig) · [Model transport](architecture.md#model-transport)

## Validating with running services

Use the running application to validate process restart and communication through the configured services. To compare context behavior across runs, replay representative work with the same model and starting history. See the [local environment](../dev/README.md) and [validation across runtime boundaries](development.md#validation).

Use the [command channel walkthrough](../dev/README.md#trying-a-command-channel) to verify that a message reaches the receiver and that closing the channel lets it finish.

### Evaluating compaction

Use the focus's saved epoch to identify committed handovers. Check stderr for interruptions. See [context budgets](running.md#context-budgets) and [persistent working history](architecture.md#persistent-working-history).

Inspect the saved handover for the expected sampled IDs and observation time. Verify that a later callback or subscription report reaches the focus that arranged it. Follow the focus's subsequent work to see whether it carries a commitment and a correction forward and can find the evidence it used. See [sampled state](input.md#sampled-state).

### Evaluating context disclosure

Compare cases where the information could inform the next decision with cases where it is incidental. Observe whether the focus uses a relevant reference or turns to unrelated work. Record request size separately. See [context and continuity](design.md#context-and-continuity).
