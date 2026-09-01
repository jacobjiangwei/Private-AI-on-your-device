# PrivateAI Repository Instructions

## Product truth

- Inspect the current implementation before describing a capability as available.
- Do not infer behavior from target architecture, schemas, protocols, test fixtures, or placeholder types.
- Report failed, skipped, blocked, and unexecuted checks exactly as they occurred.
- Describe schema, registration, adapter, argument-validation, and framework-call checks only as contract or integration-wiring evidence. Do not say a capability "passed", "works", or is "available" based on those checks.
- Reserve capability-passed language for a successful real executor result and, for model-facing behavior, a real model-driven E2E whose final user-visible outcome is verified against ground truth.

## Root-cause-first engineering

- Do not edit code, propose a fix, add a workaround, or retry a failed operation until you can state: the observed failure, the evidence gathered, one falsifiable root-cause hypothesis, the controlling code path, and the cheapest check that could disprove the hypothesis.
- Distinguish the symptom, immediate trigger, and root cause. A nearby failing line, error message, timeout, or permission denial is not automatically the root cause.
- Trace behavior to the component that owns the violated invariant. Fix that invariant at its owning abstraction instead of adding downstream conditionals, retries, fallback branches, duplicated logic, or example-specific exceptions.
- If the evidence does not yet explain why a proposed change should fix the failure, continue investigating. Do not use code edits as undirected experiments when a read, trace, focused test, debugger observation, or runtime value can discriminate between hypotheses more cheaply.
- Never repeat an unchanged command merely hoping for a different result. Retry only when testing an identified source of nondeterminism, and state what new evidence the retry can produce. Otherwise, change the hypothesis, inputs, instrumentation, implementation, or environment first.
- Implement a workaround only when the user explicitly requests one or the root fix is demonstrably blocked. Label it as a workaround and record the blocking constraint, tradeoff, and removal condition; do not present it as the completed root fix.
- After a failed validation, do not stack another speculative patch on top. First decide whether the result supports or falsifies the current hypothesis, then revise the hypothesis or make the smallest evidence-backed correction.
- Judge elegance and efficiency concretely: preserve one clear invariant, minimize states and special cases, use the owning abstraction, and maximize information gained per command or edit. Fewer investigative steps are not efficient if they create rework or conceal uncertainty.

## Tool implementation definition of done

A PrivateAI Tool is not complete when it only defines an `LLMTool`, JSON Schema, request enum, backend protocol, fixture, registry entry, or mocked result. Those pieces are contracts and test seams, not the capability.

A Tool may be described as implemented only when all of the following exist:

1. The model-facing schema and strict runtime argument validation.
2. A real executor that performs the claimed operation through the appropriate macOS framework, bounded network client, filesystem API, or isolated worker.
3. Structured success, unavailable, denied, cancelled, timeout, and failure results where applicable.
4. Explicit resource scope, output limits, cancellation, and concurrency behavior.
5. A deterministic contract test for schema, validation, and result encoding.
6. A direct integration test that executes the real framework/API/filesystem/worker behavior. Fixtures cannot satisfy this gate.
7. A model-driven E2E test in which the real Ollama model receives the Tool schema, chooses the Tool from a natural-language request, the real executor runs, and assertions prove the final user-visible answer uses the executor's real result as ground truth.

Tool selection, action selection, intermediate JSON fields, request counts, and non-empty model output are diagnostic evidence, not proof that the user request succeeded. A model-driven E2E test must assert the requested facts, values, state change, or artifact in the final observable outcome.

If an external service or protected macOS capability prevents integration testing, report the Tool as blocked or partially implemented. Do not convert service failure, permission denial, skipped tests, or fixture output into a successful capability claim.

Protected macOS capability success belongs in a signed App-hosted E2E scenario with the real bundle identity, entitlements, usage descriptions, and explicit authorization preconditions. Swift Package tests may verify argument contracts and denied/unavailable error mapping, but a branch that accepts denial or unavailability must not be named or reported as a successful capability test.

## Capability boundaries

- Keep `LLMCore` provider- and capability-neutral. It owns model contracts, the package system prompt, warmup, `ToolRuntime`, and the model/tool loop.
- Put real built-in Tool implementations in `Packages/PrivateAITools`.
- Keep the model-facing catalog small and capability-oriented. Do not create domain Tools for weather, YouTube, restaurants, news, or similar tasks when an existing capability gateway can perform them.
- Treat general-purpose local terminal execution as a primary Agent capability. Do not weaken it into a language-specific evaluator, fixed action list, executable allowlist, or keyword-based command classifier.
- Use `~/.privateAI` as the default managed execution root. Create workspaces, jobs, logs, artifacts, and execution state beneath it; do not describe it as a security sandbox unless the process boundary actually enforces confinement.
- Keep dedicated file, PDF, web, and native macOS capabilities because they provide structured semantics and permission states, not because terminal execution is a restricted fallback.
- Stream long-running command output to the App and local logs. Send bounded milestones and final structured results to the model instead of placing every output line in model context.
- Never put passwords, passphrases, tokens, private keys, or other secret interactive input in tool arguments, model messages, Agent events, conversation storage, or execution logs. Secure App input must travel directly to PTY stdin through an ephemeral channel.
- Local resource Tools must operate only within App-authorized roots, resolve symlinks before access, use format-aware binary readers such as PDFKit when applicable, and preserve raw bounded text formats such as HTML and Markdown unless the product explicitly requests a derived representation.
- A Tool is serial by default. It may opt into concurrency only when the concrete action and implementation are safe to run concurrently.

## Capability design discipline

- Before implementing or extending a capability, define its matrix of input categories, real executors/parsers, permission requirements, limits, failure states, and direct tests. Do not build capabilities one user example at a time.
- Treat a named example such as PDF, Markdown, weather, or location as evidence of a broader category to analyze, not as the complete requested scope.
- Prefer a controlling abstraction such as document-format routing or capability actions over accumulating unrelated extension checks and special cases.
- Do not claim support for an input category until a real fixture or integration test covers it.
- For terminal execution, direct tests must cover real commands, incremental output before completion, nonzero exit, timeout, cancellation of descendants, interruption state, PTY interaction, output truncation, and secret-input redaction. A mocked runner cannot satisfy the integration gate.

## Validation

- After every substantive edit, run the narrowest test that can falsify the change before editing another module.
- Build each Swift Package independently and run its focused tests.
- Before handoff, build the macOS app and report every warning and error.
