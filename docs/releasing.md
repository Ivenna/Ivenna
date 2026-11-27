# Releasing Ivenna

Tagged releases, Actions snapshots, and local builds use the same [package format](#release-packages).

## Publishing a tagged release

Push a tag on the commit you want to publish and keep the tag at that commit. The tag supplies the package's version label. It must start with `v` and follow the syntax shown by `scripts/release.sh --help`. A tag such as `v0.1.0` produces a regular release. A hyphen in the tag, as in `v0.1.0-rc.1`, marks it as a prerelease. Use a new tag for each new release.

The workflow tests and packages the tagged commit. The `publish` job checks that the tag points to the package's source commit before creating a draft. Once the package is uploaded, it checks the tag again and publishes the draft. [Release workflow](../.github/workflows/release.yml)

If `publish` stops after creating a draft, find it in GitHub Releases or open the link from the job log. Once you confirm the failed run created the unfinished draft, delete it, leave the tag in place, and rerun `publish` from the original workflow run. [Managing GitHub releases](https://docs.github.com/en/repositories/releasing-projects-on-github/managing-releases-in-a-repository) · [Rerunning a job](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/re-run-workflows-and-jobs#re-running-a-specific-job-in-a-workflow)

## Building a snapshot

Manual runs require repository write access and the workflow on the default branch. Open **Actions**, select **Release**, and choose **Run workflow**. Select the branch to build and start the run. [Running a workflow manually](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow)

Download and unpack `ivenna-package` from **Artifacts** in the run summary. It contains the three package files with the version label `snapshot-<commit-sha>`. [Downloading workflow artifacts](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/download-workflow-artifacts)

## Packaging source locally

On GNU/Linux, use the upstream Zig distribution for the version in [`.zig-version`](../.zig-version) and make its `zig` available on `PATH`. The build copies Zig's license from that distribution. Run the script from the source directory with a version label.

```sh
scripts/release.sh v0.1.0
```

The script runs the Zig regression tests and builds the executable with the same target, CPU baseline, and `ReleaseSafe` mode, which keeps Zig's runtime checks in the distributed executable. It writes the package to `dist/<version>/` using the label you pass. Run `scripts/release.sh --help` for the label syntax. [Zig build modes](https://ziglang.org/documentation/0.17.1/#Build-Mode)

## Release packages

Each package has three files with the base name `ivenna-<target>-<version>`.

- The `.tar.gz` archive contains `ivenna`, the project license, and third-party license notices under `licenses/`.
- The `.sha256` file contains the archive's checksum.
- The `.json` build record contains the version label (`version`), source commit (`commit`), working tree status before the build (`dirty`), build target (`target`), minimum glibc version (`glibc_min`), Zig version (`zig`), and UTC build timestamp (`built_at`). For source archives without Git metadata, `commit` and `dirty` are `null`.

The Release workflow builds for x86-64 GNU/Linux. Local packages use the host architecture. Use the same [installation steps](running.md#installing-the-executable) for either package.
