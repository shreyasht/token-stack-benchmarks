# Results log

Findings from individual runs, written up as they happen. This is **not**
the benchmarking methodology (see
[`token-optimization-stack/BENCHMARKING.md`](../../token-optimization-stack/BENCHMARKING.md))
and it is **not** a scored batch — entries here are pilot/smoke-test runs
plus whatever ad-hoc verification was possible for each, with the
methodology gap stated explicitly per entry. Don't read anything here as a
verified-tier pass/fail number.

---

## pilot-3 — jackson-databind #6145

**Task:** [FasterXML/jackson-databind#6145](https://github.com/FasterXML/jackson-databind/issues/6145)
— `@JsonIgnoreProperties` bypassed for Creator properties with builders and
external type ids. Hand-picked (not pulled from a dataset file — that TODO
in `scripts/run-task.sh` is still open), issue still open on GitHub at time
of writing.

**Agent's fix** (`results/pilot-3.log`, not committed — gitignored):
added an `IgnorePropertiesUtil.shouldIgnore` guard, matching the existing
`#4629` precedent, to three methods:
- `BeanDeserializer.deserializeUsingPropertyBasedWithExternalTypeId`
- `BuilderBasedDeserializer._deserializeUsingPropertyBased`
- `BuilderBasedDeserializer.deserializeUsingPropertyBasedWithUnwrapped`

Correctly left the builder's external-type-id path untouched (unimplemented
upstream — throws `reportBadDefinition`, so no fourth site applies). Added
`JsonIgnorePropertiesCreator6145Test`; agent reported 246 related tests plus
3 new tests passing.

**Why this isn't formal gold-patch scoring:** issue #6145 has no merged fix.
There's a real, currently-open community PR proposing one —
[FasterXML/jackson-databind#6146](https://github.com/FasterXML/jackson-databind/pull/6146)
— but it hasn't been accepted by maintainers, so there's no canonical patch
to diff against. `BENCHMARKING.md`'s verified tier requires a merged fix +
test suite that determines pass/fail; this task doesn't have that yet.

**What was actually checked:** the agent's fix against PR #6146's diff,
as an informal reference rather than ground truth.

| | Agent | PR #6146 |
|---|---|---|
| `BeanDeserializer.deserializeUsingPropertyBasedWithExternalTypeId` | guard added | guard added |
| `BuilderBasedDeserializer._deserializeUsingPropertyBased` | guard added | guard added |
| `BuilderBasedDeserializer.deserializeUsingPropertyBasedWithUnwrapped` | guard added | guard added |
| Builder's external-type-id path | correctly skipped | not touched |
| Guard function | `IgnorePropertiesUtil.shouldIgnore` | `IgnorePropertiesUtil.shouldIgnore` |
| Precedent cited | `#4629` | `#4629` |
| Test class | `JsonIgnorePropertiesCreator6145Test` | `IgnorePropertiesCreator6145Test` |

Two independent fixes — a real external contributor's PR and the agent's,
neither aware of the other — landed on the identical three injection points,
the identical guard function, and the same cited precedent. That's a strong
correctness signal for this one task. It is not a verified-tier pass; it's
one data point, on one hand-picked task, informally cross-checked against an
unmerged reference.

**What this doesn't tell you:** anything about token/cost savings from the
stack tools. This run used the full stack with no baseline comparison and
no ablation arms — see `BENCHMARKING.md`'s ablation design for what a real
measurement requires. This entry only establishes that the pipeline
(container → auth → agent → real fix on a real repo) works end to end.
