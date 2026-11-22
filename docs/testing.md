# Testing

Tests support Ivenna's exploratory development by catching consequential regressions while leaving interfaces and implementation free to evolve. Keep their setup, execution, and maintenance costs small enough to support routine iteration. The [development guide](development.md) sets the broader change conventions.

## Choosing tests

Choose checks from the intended behavior and the consequences of failure. Add a focused regression test when a failure would be costly or hard to notice during ordinary development. Existing tests can help identify affected behavior; revise or remove their expectations when the design changes.

Choose the smallest check that gives useful evidence at the boundary owning the behavior. Prefer observable outcomes over internal layout, exact prompt wording, or incidental serialization. A small, reversible change may need only review and a build. Judge a test by the failure it can expose and the maintenance it adds.

During development, do not write tests in advance or introduce test frameworks. Keep fixtures and setup limited to what the outcome requires. Keep tests with the component that owns the behavior, and adjust their placement as those responsibilities change.

## Running checks

Run commands from the repository root. Install the Zig version in [`.zig-version`](../.zig-version), then check tracked Zig source formatting, build Ivenna, and run the registered Zig tests:

```sh
git ls-files -z '*.zig' '*.zig.zon' | xargs -0 zig fmt --check
zig build
zig build test
```

The [root build](../build.zig) runs the registered Zig library and application tests. Library roots include internal test files through `test` blocks in `src/root.zig`. Adding a package to the test step requires a root build entry and a [dependency manifest](../build.zig.zon) entry.

For the [memory protocol tests](../apps/memory/tests.nu), install Nushell at the version used in the memory [Containerfile](../apps/memory/Containerfile). These tests also use the standard `ln` command:

```sh
nu --no-config-file --no-history apps/memory/tests.nu
```

The script uses Nushell's standard assertions, sends JSON requests directly to the handler in temporary workspaces, and removes those workspaces afterward. It uses no configuration or data from the development instance. Keep CI's Nushell version aligned with the Containerfile when upgrading it.

## Automation and validation limits

The [CI workflow](../.github/workflows/ci.yml) invokes these checks on Linux. The checks run directly with Zig and Nushell and require no deployed services or model credentials. Extend or replace automated checks when the evidence they provide justifies their execution and maintenance cost.

The email adapter tests use a local HTTP server to drop connections and count the requests that reach it. They check that a mailbox read can recover and that an interrupted send submits its draft at most once. For callbacks and working history, the tests check what stored evidence lets the adapter confirm a write after it loses the response.

Both the email and Responses adapter tests cover cancellation over plain HTTP. The Responses tests also check which parts of a tool result survive an upload failure. To measure how many request bytes reach a TLS peer, exercise the [request writer](architecture.md#model-transport) against a local HTTPS server.

The agent tests cover inference retries with the original request, delivery retention across interruption, and the arrivals that wake a focus. The session registry tests use a history store that can report a failed save after receiving the checkpoint. They check that activity completion publishes once and that a later maintenance pass republishes the same selection when confirmation was lost.

With the kernel offline, the reporter process test checks the JSON receipts and exit status a listener sees for malformed input, retries and cursor updates. Separate SQLite connections verify that a cursor conflict leaves the report key available and that retrying an acknowledged report leaves the queue and cursor unchanged. See the [reporter process test](../apps/ivenna-report/src/report_test.zig) and [store tests](../packages/subscriptions/src/root.zig).

The kernel tests interleave reports for several focuses and check which focus wakes, receives each report and can finish. They also simulate checkpoint failures before and after commit, then reconstruct the kernel against the same catalog and check that each report appears once in the receiving focus's history. See the [kernel tests](../packages/agent/src/kernel.zig).

Restoring a focus after a process restart and communicating with configured services require checking the running application. See [validation across runtime boundaries](development.md#validation) and the [local development guide](../dev/README.md).
