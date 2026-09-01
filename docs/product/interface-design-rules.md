# PrivateAI Interface Design Rules

- Status: Accepted baseline
- Scope: Native macOS App chrome, controls, chat surfaces, and WebKit transcript

## Layout Grid

Use a 4-point spacing grid. Shared values belong in `InterfaceMetrics`; views must not invent nearby magic numbers.

| Token | Value | Use |
| --- | ---: | --- |
| `spacingXS` | 4 pt | Icon-to-label micro spacing |
| `spacingS` | 8 pt | Compact internal padding |
| `spacingM` | 12 pt | Control-to-control spacing |
| `spacingL` | 16 pt | Page and toolbar edge padding |
| `controlHeight` | 28 pt | Compact toolbar controls and labels |
| `headerHeight` | 44 pt | Chat header |

## Control Geometry

- Compact controls use a 28 pt stable height and a 6 pt corner radius.
- Text fields use an 8 pt corner radius and at least 8 pt vertical, 12 pt horizontal padding.
- Status, metric, and mode surfaces must have explicit internal padding and centered content. Do not place a bare `Text` where the UI behaves as a persistent control or status label.
- Icon and text content align on the center axis. Numeric values use monospaced digits to prevent layout jitter.
- Fixed-format dynamic controls reserve enough width for their longest expected value. Streaming values must update without moving neighboring controls.
- Buttons that can use a familiar symbol use the symbol with a tooltip and accessibility label.

## Header Composition

The chat header order is stable:

```text
Connection status | Model picker | Model performance label | flexible space | activity
```

The model performance label is always present while Ollama is ready. Idle content is `TTFT — · — tok/s`; during generation it updates in place. It must not appear as transient trailing text or expose internal warmup state.

## Responsive Behavior

- Preserve the model picker and performance label as one logical group.
- Activity text yields space first and truncates to one line.
- Controls never overlap or resize vertically when labels change.
- At narrow widths, reduce model-picker width before hiding performance metrics.

## Transcript Rhythm

- Transcript content remains centered with a readable maximum width.
- User, assistant, and Tool messages use distinct semantics without nesting cards.
- Headings inside messages use document scale, not page-hero scale.
- Code blocks, inline code, lists, quotes, and links retain consistent padding and line height.
- Raw Markdown remains the copy source; rendered DOM is presentation only.

## Review Gate

Before accepting a new control or state:

1. Check idle, loading, streaming, success, failure, and long-content states.
2. Verify padding and center alignment at the smallest supported window width.
3. Confirm dynamic content does not shift adjacent controls.
4. Build the App and inspect the real running UI; compilation alone is not visual acceptance.