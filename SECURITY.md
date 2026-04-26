# Security policy

Deckhand flashes 3D-printer firmware and executes privileged operations
on a user's workstation. Bugs here can brick hardware, exfiltrate SSH
credentials, or hijack installs. Please treat this project with the
same care you would give a boot loader or a package manager.

## Reporting a vulnerability

**Do not open a public GitHub issue for security reports.** Send the
details to one of the following, in order of preference:

1. A private GitHub Security Advisory — open one at
   `https://github.com/CepheusLabs/deckhand/security/advisories/new`.
   This creates a confidential thread with the maintainers and a
   tracked CVE path if the issue warrants one.
2. Email `security@cepheuslabs.com` with the subject
   `[deckhand] <one-line summary>`. We aim to acknowledge within
   two business days.

Please include:

- A short description of the issue and the class of attack it enables.
- A reproduction recipe (or, better, a failing test).
- The affected commit or release tag.
- The platform(s) and elevation mode(s) involved (Windows UAC, macOS
  `osascript`, Linux `pkexec`).
- Whether you have already disclosed this elsewhere.

## What we treat as in-scope

- Code execution or privilege escalation via the sidecar or elevated
  helper on any supported platform.
- Any path that writes to a disk the user did not explicitly pick.
- Any path that bypasses the signed-tag or SHA-256 gate for downloaded
  images or profiles.
- Authentication, SSH, or Moonraker bypass in the stock-keep and
  fresh-flash flows.
- Secret or confirmation-token leakage in logs, crash dumps, or IPC
  notifications.
- Supply-chain issues in the release pipeline (signing, SBOM,
  checksum manifest).

## What is out of scope

- Issues that require local admin already and target files the user
  owns (Deckhand runs with whatever the user gave it).
- Denial of service via absurdly large images — the user controls
  what they ask Deckhand to download.
- Bugs in a *profile* we ship — file those against the
  [deckhand-profiles](https://github.com/CepheusLabs/deckhand-profiles)
  repo unless the profile exploits something Deckhand itself trusts.
- Upstream vulnerabilities in third-party packages that we haven't
  pinned, unless our specific version or usage makes them exploitable.

## Expectations

- We will keep the discussion private until a fix is available and
  an advisory is ready to publish.
- We will credit reporters by name or handle in the advisory unless
  you ask us not to.
- We aim for a fix within 90 days of a validated report. We will let
  you know early if we can't hit that, and will coordinate a
  disclosure timeline with you.

## Hardening checklist (for reviewers)

When reviewing a patch in a security-sensitive area, confirm:

- [ ] No new path writes to a disk that `disks.safety_check` has
      not approved.
- [ ] No new code executes profile-supplied Dart or shell without
      gating on `ProfileScriptRuntime.enabled`.
- [ ] Every `disks.*` or `os.*` RPC adds a `ParamSpec` for its params.
- [ ] Confirmation tokens, SSH passwords, and PGP keyrings are not
      written to the sidecar log (`redactParams` covers them).
- [ ] Downloaded artifacts are verified against a sha256 before use.
- [ ] A failing signed-tag check fails the operation, not just logs a
      warning.
