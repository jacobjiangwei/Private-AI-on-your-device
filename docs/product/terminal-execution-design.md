# PrivateAI Terminal Execution Design

- Status: Accepted product direction; implementation pending
- Date: 2026-08-30
- Scope: General-purpose local terminal execution for the PrivateAI macOS Agent
- Planned model-facing name: `terminal`
- Planned Swift adapter: `PrivateAITools.TerminalTool` (`TerminalTool.swift`)

## Product Contract

PrivateAI is a local Agent with real terminal capability. It can run the commands and command-line runtimes available to the user, including `zsh`, Git, Homebrew, Python, Node.js, Swift, package managers, builds, tests, scripts, pipelines, redirections, installers, and long-running processes.

Terminal execution is not a reduced code sandbox, a language-specific evaluator, or an executable allowlist. The model-facing name `terminal` is a gateway into a general-purpose local execution subsystem.

Local means that inference, orchestration, execution state, logs, and artifacts remain on the user's Mac without requiring a hosted PrivateAI service. Commands may use network services when the user and operating environment permit them.

## Managed Execution Root

PrivateAI creates this directory on first execution:

```text
~/.privateAI/
    workspaces/
    jobs/
    logs/
    artifacts/
    state/
```

- `workspaces/` contains repositories, generated projects, and durable working trees managed by PrivateAI.
- `jobs/` contains request metadata and non-secret lifecycle state for active and completed executions.
- `logs/` contains complete bounded-by-storage execution logs. Model context receives only selected output tails and summaries.
- `artifacts/` contains retained outputs linked to conversations and execution receipts.
- `state/` contains versioned execution-service state needed for interruption recovery.

Every command defaults to a workspace or job directory beneath `~/.privateAI`. Relative paths resolve from that working directory. A caller may select another user-authorized working directory when product policy permits it.

`~/.privateAI` is the managed ownership and lifecycle root, not a security claim that a general-purpose shell cannot address paths outside it. Actual filesystem authority is determined by the execution process, App Sandbox or direct-distribution configuration, security-scoped bookmarks, macOS permissions, and explicit user authorization.

## Component Ownership

| Component | Responsibility |
| --- | --- |
| `LLMCore` | Provider-neutral model loop, tool proposal handling, execution events, cancellation propagation, and final tool-result delivery |
| `PrivateAITools.TerminalTool` | Model-facing schema, strict argument validation, and conversion between model calls and execution requests/results |
| `ExecutionKit` | Job lifecycle, process and PTY execution, output streaming, process-tree cancellation, timeout, logs, artifacts, and interruption state |
| Execution worker | Runs commands outside the model process and reports versioned events over local IPC |
| macOS App | Command and progress UI, Stop control, workspace authorization, policy settings, and secure interactive input |

`LLMCore` must not import process, PTY, shell, AppKit, or authorization implementations. `TerminalTool` must not duplicate the execution engine.

## Model-facing Request

The primary operation accepts a complete shell command rather than a language-specific program:

```json
{
  "command": "brew install ffmpeg && ffmpeg -version",
  "working_directory": "~/.privateAI/workspaces/media-task",
  "timeout_seconds": 3600,
  "interaction": "automatic"
}
```

The execution subsystem runs general shell work through the user's configured supported shell, initially `/bin/zsh -lc`. It may additionally offer direct executable invocation as an optimization, but direct invocation must not replace or weaken full shell capability.

The schema must not expose passwords, passphrases, tokens, private keys, or other secret values.

## Long-running Jobs and Events

Execution is a job, not a single `async throws -> String` function. Each job has a stable identifier and emits ordered events:

```swift
public enum ExecutionEvent: Sendable {
    case started(ExecutionStarted)
    case stdout(ExecutionOutputChunk)
    case stderr(ExecutionOutputChunk)
    case progress(ExecutionProgress)
    case artifact(ExecutionArtifact)
    case userInputRequired(ExecutionInputRequest)
    case finished(ExecutionResult)
}
```

The worker and service must preserve ordering within each output stream, drain stdout and stderr concurrently, and avoid blocking when a child process fills a pipe.

High-frequency output is sent to the App UI and local log. Ordinary output does not repeatedly wake the model. The Agent Runtime sends information back to the model at these boundaries:

- the process finishes, fails, times out, or is cancelled;
- the process reaches a decision point that requires model reasoning;
- a meaningful artifact is produced;
- the user supplies a non-secret decision that changes execution.

The final model-visible result is structured and bounded:

```json
{
  "status": "succeeded",
  "job_id": "01J...",
  "command": "swift test",
  "working_directory": "/Users/user/.privateAI/workspaces/project",
  "exit_code": 0,
  "duration_seconds": 42.8,
  "stdout_tail": "Test run with 38 tests passed",
  "stderr_tail": "",
  "output_truncated": true,
  "log_artifact": "artifact://execution/01J/log"
}
```

The complete log is not copied into the model context. Output truncation is explicit and the retained local log remains inspectable by the user.

## Pipe and PTY Modes

- Pipe mode is preferred for non-interactive automation because stdout and stderr remain distinct and structured.
- PTY mode is used for commands that require terminal semantics, interactive prompts, progress rendering, or user input.
- Automatic mode begins with the execution strategy selected by the service and may report that user interaction is required.

The UI must always show the command, current working directory, execution status, elapsed time, recent output, and a Stop control.

## Passwords and Secret Input

Secret input is owned by the App, not the model or Tool protocol.

When an interactive job needs protected input:

1. The execution service emits `userInputRequired` without the secret value.
2. The App presents a secure input control.
3. The App sends the value through an ephemeral in-memory channel directly to PTY stdin.
4. The value is not echoed, persisted, added to an `AgentEvent`, encoded in a tool result, or sent to Ollama.
5. The App and execution service discard their temporary references after the write completes.

Prompt-text matching such as searching for `Password:` is not a complete security mechanism and must not be the sole detector. Users must be able to provide interactive input explicitly when a PTY job is waiting.

PrivateAI must not implement privileged execution by passing a model-visible or logged password to `sudo`. System-level privileged operations require a separately designed macOS Authorization Services and privileged-helper boundary. Until that boundary exists, unsupported privileged operations are reported accurately.

## Cancellation and Recovery

- Cancelling an Agent run cancels its active execution jobs.
- Cancellation terminates the process group or equivalent descendant tree, not only the immediate shell.
- A graceful termination period may precede forced termination.
- App or worker termination records an unfinished job as `interrupted` or `unknownOutcome` according to observed side effects.
- An interrupted command is never silently replayed.
- Long-running servers may remain active only when the execution request and product policy explicitly select a persistent job lifecycle.

## Authority and Policy

PrivateAI does not classify intent by command keywords and does not use a command allowlist as its primary safety boundary. Users choose an execution policy such as autonomous execution or confirmation, and macOS determines the process's actual authority.

The execution worker must not inherit PrivateAI service credentials or unrelated sensitive environment variables by default. Environment construction is explicit and inspectable. Commands execute as the current user unless a future privileged-helper design states otherwise.

## Definition of Done

Terminal execution is not implemented until all of the following exist:

1. A real process and PTY executor runs general shell commands beneath `~/.privateAI` by default.
2. stdout and stderr stream to the App while the job is active.
3. Completion, nonzero exit, timeout, cancellation, process-tree termination, and interruption are directly tested.
4. A long-running integration test proves incremental output arrives before completion.
5. A real external command or package installation test proves the command is not a fixture-only executor.
6. Secret input bypasses model messages, execution logs, and persistent storage in direct tests.
7. A model-driven E2E test proves the real Ollama model chooses terminal execution, the real command runs, and the model uses its result.
8. The macOS App displays live progress and can stop the process tree.

Until these gates pass, documentation and UI must describe terminal execution as planned or partially implemented rather than available.