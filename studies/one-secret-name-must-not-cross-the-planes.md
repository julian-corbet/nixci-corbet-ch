# One Secret name must not cross the planes

**Finding.** A CI server and the runner it hands work to share one credential *value* — the shared
secret the runner authenticates with. Everything else the server holds, the runner must never be
able to read: the forge's OAuth client secret, which is the ability to impersonate the CI server to
the forge and therefore to every repository the forge holds; and the server's admin token, which is
the ability to read and rewrite every repository-scoped secret the platform has.

So the tempting shape — one Secret object with the shared value in it, mounted by both — is a full
compromise dressed as a convenience. The correct shape is **two Secret objects, in two namespaces,
one of which carries only the shared value.**

That is a statement nobody can enforce by reading a declaration carefully, because the two halves
are written months apart and the wrong version looks tidier.

## What the module does

`modules/cluster.nix` collects every Secret **name** each workload references, by either route — a
named credential role, or a whole-Secret `envFrom` — and refuses at eval any name that appears on
both planes. The message names the Secret and every workload on each side, because the fix is a
decision (unseal a second object) rather than an edit.

Two published, read-only options make the split *data* rather than a claim:

```
nixci.controlSecrets    # everything the control plane names
nixci.executionSecrets  # everything a build script could reach
```

They must be disjoint, and the second one should be short and boring. A reader can check that in one
command instead of believing a paragraph.

## Why `envFromSecrets` is counted the same way

A whole-Secret mount is the easiest way to hand the execution plane something it should not have,
precisely because it names no keys: the declaration says "give this workload that object", and what
that object contains changes later, without the declaration changing. So it is counted identically,
and `checks/cluster-eval.nix` has a case for exactly that route
(`control-secret-mounted-wholesale-in-the-execution-plane`) beside the named-role one.

## The floor underneath it

The guard is only meaningful if the two planes are two namespaces. A Kubernetes Secret is namespaced,
so one namespace for both planes makes the whole split unenforceable by anything — a runner in the
control namespace can mount the server's Secret whatever any Nix module says. Hence a separate,
blunter refusal: `controlNamespace` and `executionNamespace` must differ, checked the moment
workloads exist on both planes.

And there is no per-workload `namespace` option anywhere in the module, so the namespaces cannot be
converged one declaration at a time either.

## What the render check adds

`checks/cluster-render.nix` greps every rendered execution-plane manifest for the control plane's
Secret name and fails if it appears. That is the same invariant asserted against the bytes that
actually reach the cluster, which is the only place it finally matters.

## The related asymmetry, which is not enforced here

A pipeline's *own* build secrets — a deploy key, a signing key, a registry token — should not be
mounted on the runner either. They belong in the CI server's own repository-scoped store and are
injected into the one pipeline that declares them, at run time. Otherwise every repository's CI can
read every other repository's keys, and the fact that they are all in the execution plane makes that
invisible to the guard above.

This repository cannot check that: it is a property of how pipelines are written, not of what is
declared here. It is recorded in the runner entries' notes so that the person reading `credentials`
and wondering where the rest go finds the answer in the same place.
