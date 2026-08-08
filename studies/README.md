# studies

Written-up findings: things that were checked in [`../experiments/`](../experiments/README.md) or
paid for in production, turned out to matter, and are worth recording properly — with the reasoning,
not just the result.

A study earns its place here once it changed a decision in the main project. See the main
[README](../README.md) for the project itself.

| File | Finding |
|---|---|
| `the-execution-plane-renders-no-service.md` | Every runner dials out, so nothing needs an inbound address in the one plane where code somebody pushed executes. Made the boundary structural at three levels instead of documented at one: the `exposure`/`slot`/`namespace` options do not exist on that plane, no execution-plane catalogue entry declares a port (so the app grammar emits no Service for one), and the render check reads the manifests back and asserts the absence in both directions. |
| `a-forge-is-cis-code-hosting-half.md` | A git forge holds CI's input, fires its trigger and is its identity provider — in a Woodpecker-shaped server the OAuth login *is* the repository connection. Which settled that the forge belongs in this repository, and that a forge somebody else runs belongs here too: it is declared as a `reference`, renders no object at all, and is still checked against by the runners and servers that depend on it. |
| `one-secret-name-must-not-cross-the-planes.md` | A CI server and its runner share one credential *value* and must never share one Secret *object* — everything else in the server's Secret is the ability to impersonate it to the forge. Produced the load-bearing invariant of the repository (a Secret name on both planes fails eval, naming both sides), the two published `controlSecrets`/`executionSecrets` lists, the refusal of one namespace for both planes, and a grep over the rendered bytes. |
| `a-successful-match-reported-as-a-failure.md` | Under `set -o pipefail`, a pipeline into `grep -q` inverts its own answer once the left-hand side outgrows a pipe buffer: `-q` exits on the first match, the writer dies of SIGPIPE with 141, and `pipefail` makes 141 the verdict. So the upstream-coordinate verifier reported real coordinates as missing, and only for the large indexes. Produced the here-string rewrite of `check_chart_http`, the same treatment for the `--tags` leg's `head`, and the rule that nothing exiting early may sit downstream of a pipe in a script that judges anything. |
| `a-warm-runner-is-a-single-writer.md` | Steps that run as processes in the runner's own pod share its filesystem, which is both the point and the constraint: two copies corrupt the shared package store, and the corruption surfaces days later in an unrelated build. Produced the absence of any replica option, the `state`-versus-`caches` split (backing one is mandatory, the other optional), and the rule that a cache's environment is emitted only when that cache is actually backed. |
