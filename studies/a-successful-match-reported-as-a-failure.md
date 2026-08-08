# A successful match, reported as a failure

**Finding:** under `set -o pipefail`, a pipeline into `grep -q` reports a SUCCESSFUL match as a
failure whenever the left-hand side has more to say than a pipe buffer holds. The verifier that
exists to tell you whether a coordinate is real says it is gone, and says it only for the large
inputs — which is the shape of bug that survives review, survives a short test, and looks
intermittent when it finally shows up.

## The mechanism

`grep -q` exits the instant it matches; that is the entire point of `-q`. The process still writing
into the pipe then gets SIGPIPE and dies with status 141. `pipefail` promotes the highest-numbered
non-zero status in the pipeline to the pipeline's own, so the `if` sees 141 and takes the else
branch. grep's own 0 — the answer to the question actually asked — is discarded.

Whether it fires is a question about SIZE, not about correctness. A writer whose whole output fits
in the pipe buffer (64 KiB on Linux) completes its write before grep can exit, so the pipeline is
honest. One byte past that and the writer blocks, grep exits on its first match, and the verdict
inverts. Nothing about the declaration changes; only how much upstream has published.

`head` is the same bug with a different trigger — it exits once it has its N lines — and it was in
here twice over: `... | grep 'version:' | head -n "$tags"`.

## What it cost

The sibling repository this script was copied into ran it first, against chart repositories large
enough to matter, and it reported three of eight real upstream coordinates as missing from indexes
that plainly contain them.

Reproduced here against the same code and real input. `check_chart_http`, taken verbatim from this
repository before the fix, on the `prometheus-community` index — 6.2 MB, 1104 lines matching the
needle:

```
  FAIL      chart -> https://prometheus-community.github.io/helm-charts :: kube-prometheus-stack
            is not in that repository's index
```

The same function on this repository's own classic chart repository — 13.7 kB — reports `OK`. Both
answers come from the same code on the same day. Only the size differs.

## What shipped

The pipe is gone, not the `-q`:

```sh
if grep -q "name: *$name" <<<"$index"; then
```

A here-string is a file the shell hands grep, so there is no writer left to kill and the match
status is the whole status. The `--tags` leg collects its lines into a variable first and feeds
`head` a here-string too, for the same reason. With the fix in place the large index reports `OK`
and the exit status is 0, and the real catalogue still verifies clean end to end.

## The general shape, for the next script in this family

Under `pipefail`, **nothing that exits early may sit on the right-hand side of a pipe**: `grep -q`,
`grep -m N`, `head`, `sed '.../q'`. Either the reader must consume everything, or the data must
reach it without a writer to kill — a here-string, a process substitution the reader owns, or a
temp file.

And a narrower rule for anything in `experiments/`: a verifier that can report a wrong answer is
worse than no verifier, because its answers arrive already labelled as checked. Size-dependent
behaviour is exactly the kind that a hand-run script never gets a second opinion on.

## How this was nearly un-found, which is the more transferable part

Two searches were run for this bug and both returned confidently wrong answers.

**Searching for the token instead of the shape.** A grep for `grep -q` matches the prose that warns
against `grep -q` — including the comment written directly above the fix. Every occurrence in this
repository is now in a comment saying not to do it, so a token search reports the bug as present in
a file that no longer has it. The search that works is restricted to the SHAPE, `\|\s*grep[^|]*-q`,
and narrowed further to files that actually set `pipefail`, since the construct is harmless without
it.

**Searching the working tree instead of a commit.** A repository somebody is mid-way through fixing
does not contain its own defects any more; it contains the fixes. Grepping the checkout answers
"what does this tree say today", which is a question about the editor, not about the code that
shipped. `git show <rev>:<path>` answers the question actually being asked.

Neither instrument is wrong in general and both are the reflex. They are wrong for THIS class of
question — "does this defect exist, and where did it come from" — and the tell is that both failure
modes return a clean negative, which is the answer nobody re-checks.
