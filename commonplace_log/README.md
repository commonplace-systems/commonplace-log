# CommonplaceLog

The Elixir reference implementation of the Commonplace Monotonic Log: an
append-only log made of independent, gapless per-writer sequences, merged by
prefix without consensus, with writer forks reported and refused.

The full README, protocol specification, conformance corpus, and the
TypeScript workalike are in the repository root:
<https://github.com/commonplace-systems/commonplace-log>.

```elixir
def deps do
  [{:commonplace_log, "~> 0.1.0"}]
end
```

Licensed under the MIT License.
