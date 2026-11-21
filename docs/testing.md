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

The Zig packages selected in the [root build](../build.zig) use Zig's built-in tests. Their package roots include internal test files through `test` blocks in `src/root.zig`; new tests in those files need to be reachable through these imports. Adding a package to this test step also requires a root build entry and a [dependency manifest](../build.zig.zon) entry.

For the [memory protocol tests](../apps/memory/tests.nu), install Nushell at the version used in the memory [Containerfile](../apps/memory/Containerfile). These tests also use the standard `ln` command:

```sh
nu --no-config-file --no-history apps/memory/tests.nu
```

The script uses Nushell's standard assertions, sends JSON requests directly to the handler in temporary workspaces, and removes those workspaces afterward. It uses no configuration or data from the development instance. Keep CI's Nushell version aligned with the Containerfile when upgrading it.

## Automation and validation limits

The [CI workflow](../.github/workflows/ci.yml) invokes these checks on Linux. The checks run directly with Zig and Nushell and require no deployed services or model credentials. Extend or replace automated checks when the evidence they provide justifies their execution and maintenance cost.

The Responses and email adapter tests use local HTTP servers to interrupt transfers and cancel requests. The Responses tests also check what remains of a tool result when a file upload fails. The agent tests simulate a retry delay to verify that inference resumes with its original request. They also check which deliveries survive an interruption and which arrivals wake the focus.

Restoring a focus after a process restart and communicating with configured services require checking the running application. See [validation across runtime boundaries](development.md#validation) and the [local development guide](../dev/README.md).
