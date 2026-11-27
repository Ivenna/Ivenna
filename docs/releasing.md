# Releasing Ivenna

For a public release, a Git tag identifies both the version and the source commit. A snapshot uses `snapshot-<commit-sha>` as its label, and a local package uses the label passed to the packaging script. All three use the same package format.

## Release packages

The files in a package share the base name `ivenna-<target>-<version>`.

- The `.tar.gz` archive contains `ivenna`, Ivenna's `LICENSE`, and third-party license notices under `licenses/`.
- The `.sha256` file contains the checksum for verifying the archive after download or transfer.
- The `.json` build record identifies the source commit, working tree status, build target, minimum glibc version (`glibc_min`), Zig version, and build time. When building from a source archive without Git metadata, the record uses `null` for the commit and working tree status.

GitHub release packages target x86-64 GNU/Linux. Use the matching build record to check the required glibc version. Follow the [installation steps](running.md#installing-the-executable) to verify and use a package.

## Publishing a tagged release

Push a `v*` tag on the commit you intend to publish. The [Release workflow](../.github/workflows/release.yml) tests and packages that commit, then checks that the tag still points to it before creating the GitHub release. Use a tag such as `v0.1.0` for a regular release. A hyphen in the tag, as in `v0.1.0-rc.1`, marks it as a prerelease.

Once a release is published, use a new tag for a new build. The GitHub CLI uploads release assets to a draft before publishing. If an upload is interrupted, rerun the publish job to resume the existing draft. The job refuses to overwrite a published release. [GitHub CLI release creation](https://cli.github.com/manual/gh_release_create#immutable-releases)

## Building a snapshot

Run **Release** manually from the Actions tab and select the branch to build. GitHub enables manual runs when the workflow is on the default branch. Download and unpack `ivenna-package` from the run summary. The snapshot stays in Actions. [GitHub manual workflow runs](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow)

## Packaging source locally

On GNU/Linux, use the upstream Zig distribution for the version in [`.zig-version`](../.zig-version) and make its `zig` available on `PATH`. The build copies Zig's license from that distribution. Run the script from the source directory with a version label.

```sh
scripts/release.sh v0.1.0
```

The script runs the Zig regression tests in `ReleaseSafe`, builds the executable in `ReleaseFast`, and writes the package to `dist/<version>/`. For label syntax, run `scripts/release.sh --help`.
