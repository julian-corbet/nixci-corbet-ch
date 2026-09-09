Checks are selected through `.ci/ccid.toml` and run by the pinned shared ccid runner on a trusted worker.

The default selection is `native`. Native Linux success does not certify a foreign architecture, a separately selected image or hardware gate, or publication. Use `list` to inspect available native Nix checks, and select existing results or affected checks before scheduling more work.

Additional coverage limits:

- Independent exact check inventory clients-eval/cluster-eval/cluster-render must survive command extraction.
- Remote-current native ARM matrix is additional mandatory platform coverage; an x86 Crow pass cannot replace it.
