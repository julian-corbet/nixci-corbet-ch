# Running checks

Run `ci/check` on a trusted build worker. The default runs the existing checks for
that worker's architecture with one build job, one build core and one evaluation
core. `ci/check list` lists the actual check inventory and refuses empty coverage.
Use `ci/check CHECK` to rerun an affected check after diagnosing a failure.

`ci/check eval` evaluates every declared system without building check outputs.
Import-from-derivation can still realize evaluation dependencies. This is not
native execution on a foreign architecture. `ci/check all-systems` needs a builder
for every declared check platform and fails if one is unavailable.

During the hosted CI outage, verification is manual through Crow's `ci` workflow.
Stage a `git archive` of the approved commit on the trusted worker, then dispatch
that published revision with `SOURCE_ARCHIVE` set to its worker-visible path and
`SOURCE_SHA256` set to its digest. Set `CHECK_TARGET` to `native`, `eval`, `list`,
`all-systems`, or one check name. Crow verifies both the archive digest and its
embedded Git commit before extracting it. Only trusted reviewed source belongs
on a worker that shares the build environment.

Automatic push validation is not configured during this manual outage mode.
Record the Crow run and exact source commit when reviewing a change. Reuse
results for unchanged source, dependencies, toolchain and environment; inspect
an existing run before submitting another one. GitHub remains an explicit manual
fallback where a workflow exists. Do not count an unrun platform, package,
hardware test, or publication gate as passed.

The source archive avoids a GitHub checkout. Locked flake inputs still need their
source in the Nix store/cache or an accessible authenticated source mirror.
