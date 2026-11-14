# NotchPulse

A Dynamic-Island-style pill around the MacBook notch that shows what your coding agents and your Mac are up to — at a glance.

NotchPulse is a borderless `NSPanel` hosting a SwiftUI view, running as a menu-bar-less agent app (`LSUIElement`). Collapsed, it shows status orbs and a sparkline next to the notch. Hover to expand it into two columns.

## Features

- **Agents column** — a read-only monitor of your local T3 Code state: running/idle/errored threads at a glance, with a click to deep-link straight into a thread (`t3code://threads/<env>/<thread>`).
- **System column** — CPU load, memory, network throughput, battery, and SoC temperature, with live sparklines.
- **Read-only, no network, no telemetry.** NotchPulse never writes to T3 Code's data and never opens a network connection.

## Requirements

- macOS 14 (Sonoma) or later. A Mac with a notch is recommended; on other Macs the pill floats just below the menu bar.
- Swift 6 toolchain — Xcode 16+ or a recent Command Line Tools install.
- T3 Code is optional. Without it the Agents column is simply empty; use `--mock` to preview the UI with sample data.

## Build & run

```sh
# Build
swift build

# Run with sample data, expanded
swift run NotchPulse --mock --expanded

# Build a release .app bundle (build/NotchPulse.app) and launch it
./scripts/bundle.sh --open
```

## Flags

| Flag                              | Description                                                        |
| --------------------------------- | ------------------------------------------------------------------ |
| `--mock`                          | Use built-in sample data instead of live data.                     |
| `--mock-scenario=busy\|calm\|idle\|hot` | Pick a sample scenario (implies `--mock`). Default: `busy`.        |
| `--expanded`                      | Keep the island expanded (handy for screenshots and design work).  |

## How it works

| Data              | Source                                                                                     |
| ----------------- | ------------------------------------------------------------------------------------------ |
| T3 Code threads   | `~/.t3/userdata/statev2.sqlite`, opened **read-only**                                      |
| T3 Code liveness  | `pid` from `server-runtime.json`; environment from `environment-id` (for deep links)       |
| CPU               | `host_processor_info`                                                                      |
| Memory            | `host_statistics64` (VM info) and kernel memory-pressure sysctls                           |
| Network           | `sysctl` `NET_RT_IFLIST2` interface counters                                               |
| Battery           | IOKit power sources                                                                        |
| SoC temperature   | Private `IOHIDEventSystemClient` API, resolved at runtime with `dlsym`                     |

The T3 Code base directory defaults to `~/.t3` and can be overridden with the `$T3CODE_HOME` environment variable.

## Privacy

NotchPulse reads local files and system counters only. The T3 Code database is opened read-only, there is no networking code, and nothing ever leaves your machine.

## Caveats

- SoC temperature relies on a private Apple API resolved via `dlsym`. It may stop working on a future macOS release; the rest of the app is unaffected.
- The app bundle is ad-hoc signed, not notarized. On first launch Gatekeeper may block it — right-click the app and choose **Open**.

## License

[MIT](LICENSE)
