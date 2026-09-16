[🇺🇸 English](./README.md) · [🇻🇳 Tiếng Việt](./README.vi.md)

# Unity CI Build

> Build Unity projects in the background while you keep working in the Editor.

Windows · Unity 6 · Android · PowerShell 5.1+

## Problem

A Unity Android build can lock the Editor for 20–40 minutes. A separate workspace with its own `Library/` keeps development and build work independent.

## Idea

Send a build request and build a specific Git commit in an isolated workspace:

```text
Developer project → queue → build workspace → Unity batchmode → APK/AAB
```

## Solution

- Build from Unity, batch files, or PowerShell.
- Build a commit without changing the developer checkout.
- Use a local Git worktree or a remote build agent.
- Reuse Unity `Library` with fingerprint-based invalidation.
- Track queues, cancellation, logs, Discord progress, and artifacts.
- Recover stale worktrees and support multiple projects.

## Quick Start

```powershell
.\install.bat
.\build.bat
```

For a separate machine, run `install-agent.bat` on the build machine, then pair the developer machine:

```powershell
.\ci.ps1 pair BUILD-PC-01
```

## Installation

The installer checks PowerShell, Git, Unity Hub, the required Editor, Android Build Support, Android SDK/NDK, OpenJDK, and disk space.

The agent bootstrap prepares the CI root, SMB share, firewall, Scheduled Task, heartbeat, Unity CLI, and Android modules. Authenticate before first automatic provisioning:

```text
unity auth status
unity auth login
```

## Daily Usage

```powershell
.\ci.ps1 build
.\ci.ps1 build -Branch release/1.2
.\ci.ps1 build -Project SE-001
.\ci.ps1 build -Format aab -Config release
.\ci.ps1 status
.\ci.ps1 queue
.\ci.ps1 cancel
.\ci.ps1 doctor
```

Inside Unity, use `CI Build > Dashboard` or `Ctrl+Alt+B`.

## How It Works

The client writes a job to `queue/` with a temporary file and atomic rename. The runner claims it in `processing/<agent>/`, checks out the requested commit, runs Unity batchmode, and writes the result to `results/`.

## Local Build vs Build Agent

| Mode | Use case | Workspace |
|---|---|---|
| Local | One developer machine | Local worktree |
| Build agent | Dedicated or second machine | Agent worktree or clone |

Remote builds use SMB for queue, cancellation, results, logs, and read-only artifact access. Only pushed commits are available to a remote agent.

## Git Commit / Branch Behavior

Every job records a branch and commit SHA. The client reads the selected branch without checking it out, so local changes are not changed. Push the commit before a remote build; artifact names include branch and short commit.

The build agent treats queue metadata as untrusted input. A remote must use an approved HTTPS/SSH form, and a configured project remote cannot be replaced by a different queue value. Only point the agent at repositories your team trusts.

## Worktree + Library Cache

The runner fingerprints the actual Unity Editor version, `ProjectSettings/ProjectVersion.txt`, `Packages/manifest.json`, and `Packages/packages-lock.json`.

Matching fingerprints preserve all `Library`, `Temp`, and `obj` state. A changed or unknown fingerprint clears those directories before Unity starts. `Library/PackageCache` is not deleted separately on every build.

## Self-Healing Worktree

Setup and the runner validate the Git checkout and recover in this order:

```text
REUSE → REPAIR → RECREATE → FAIL with the Git error
```

Cleanup is restricted to CI-owned paths.

## Progress / Discord

The runner updates one Discord card with project, branch, commit, stage, elapsed time, ETA, and final result. Stages are inferred from Unity logs, including import, compile, IL2CPP, Gradle, and packaging.

## Artifact Delivery

Artifacts can remain on the build machine, be copied to a synchronized folder, or be uploaded with `rclone`:

```powershell
.\ci.ps1 drive
```

Upload failure is reported separately and the local artifact path is preserved.

## Release / Keystore / Secrets

Release builds require a keystore, alias, and passwords. Credentials are checked before building and imported on the build machine:

```powershell
.\ci.ps1 import-secrets <bundle.json>
```

Secrets use Windows DPAPI. The keystore is outside the SMB share in `UnityCISecure`; passwords never enter queue jobs.

## Important Rules

1. Build from a specific commit.
2. Never change the developer checkout to build another branch.
3. Run one heavy Unity build per machine.
4. Reuse `Library` only when its fingerprint is valid.
5. Never patch generated files under `Library/PackageCache`.
6. Never commit or queue secrets.
7. Treat the agent as a build worker, not a remote shell.
8. Fail early when release credentials are missing.

## Troubleshooting

### PixelPerfectCamera or PackageCache errors

Regenerate the full cache through the fingerprint policy. Do not patch `Library/PackageCache`. If the error remains, investigate package and Unity compatibility.

### Android SDK is missing

Install Android Build Support, Android SDK & NDK Tools, and OpenJDK. Run `.\ci.ps1 doctor`.

### Worktree or .git errors

```powershell
.\ci.ps1 repair
```

Review `runner.log` and the printed Git error.

### Build agent is not running

```powershell
.\ci.ps1 status
.\ci.ps1 agent-doctor
```

### Build failed without a clear cause

Inspect `logs/<job-id>.errors.txt` and the complete `logs/<job-id>.log`.

### Drive upload failed

Run `.\ci.ps1 drive`; the artifact remains on the build machine.

### Remote build cannot find a commit

Push the branch and commit to the configured Git remote.

## Project Structure

```text
Build_CICD/
├── install.bat
├── install-agent.bat
├── setup.ps1
├── setup-agent.ps1
├── ci.ps1
├── runner.ps1
├── lib/                  shared PowerShell modules
└── unity/                Unity Editor scripts

UnityCI/
├── queue/                waiting jobs
├── cancel/               cancellation flags
├── processing/<agent>/   claimed jobs
├── worktree/<project>/   build checkout
├── builds/<project>/     APK/AAB output
├── results/              result JSON
├── logs/                 Unity and error logs
└── agents/               heartbeats
```

## Multiple Projects

One CI root and queue can serve multiple projects. Each project has its own Git remote, Unity version, worktree, output, and release configuration. One heavy Unity job runs per machine.

## Feature Status

Stable features include Android APK/AAB builds, local workspaces, Git worktrees, branch builds, cancellation, Discord results, artifact publishing, heartbeats, cache fingerprints, and worktree recovery.

## Experimental

Build-agent bootstrap, developer pairing, automatic Unity CLI provisioning, Android module provisioning, and extended doctor checks should be validated on a secondary machine before release use.

## Coming Soon

- Zero-touch build-agent provisioning.
- Complete on-demand Unity Editor provisioning.
- Stronger agent trust and pairing.
- Firebase App Distribution.
- Discord `/build` command and multi-agent routing.
- macOS and iOS build agents.

## Philosophy

This project is intentionally smaller than Jenkins or a hosted CI platform. It focuses on one practical outcome: a small Unity mobile team can press Build and continue working immediately.

## Star / Issues

If Unity CI Build saves time, star the repository. For a bug report, open an Issue with `runner.log`, `logs/<job-id>.errors.txt`, Unity version, Windows version, and local or remote build context.
