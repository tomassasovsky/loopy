# Self-hosted Yocto CI runner

A GitHub Actions self-hosted runner for the `appliance-release.yml` workflow's
Yocto/RAUC build. **Hybrid setup**: the arm64 Flutter app-build step stays on
GitHub's free native `ubuntu-24.04-arm` runner (no QEMU, no correctness risk —
the app Dockerfile isn't built for cross-arch emulation); only the heavy
~2h Yocto build moves here, where a persistent local sstate cache pays off far
more than GitHub's Actions cache (which round-trips over the network every run).

This is **opt-in**: the workflow's default path is unchanged. Self-hosted only
runs when a `workflow_dispatch` explicitly selects `runner: self-hosted`.

## 1. Create the PAT

GitHub → Settings → Developer settings → **Fine-grained personal access
tokens** → Generate new token.

- **Resource owner**: your account (`tomassasovsky`)
- **Repository access**: Only select repositories → `loopy`
- **Permissions** → Repository permissions:
  - **Administration**: Read and write (required to register/manage a
    self-hosted runner on the repo)
  - Metadata: Read-only (default, already included)
- No other permissions needed. Copy the token — you won't see it again.

## 2. Deploy on Portainer (git-repository stack)

1. Portainer → Stacks → Add stack → **Repository** →
   `https://github.com/tomassasovsky/loopy`, compose path
   `deploy/ci-runner/docker-compose.yml`.
2. Under **Environment variables**, add `GH_RUNNER_PAT` = the token from
   step 1. (Set it here, in Portainer's own env store — never in the compose
   file or git.)
3. Deploy. The container registers itself with GitHub on startup; check
   GitHub → `loopy` repo → Settings → Actions → Runners for
   `proxmox-yocto` to show **Idle**.

## Verify

```bash
gh api repos/tomassasovsky/loopy/actions/runners --jq '.runners[] | "\(.name) \(.status) \(.labels[].name)"'
```

## Trigger a self-hosted build

```bash
gh workflow run appliance-release.yml --repo tomassasovsky/loopy \
  -f channel=experimental -f runner=self-hosted
```

## Disk / resource notes

The Yocto build (sstate + downloads + transient `tmp/work`) wants roughly
60-100 GB of headroom on the host, most of it reusable across builds via the
`yocto-sstate` named volume. Sized against the box's 108 GB free at setup time
— revisit if other services on the same host grow.

## Removing it

Delete the Portainer stack (the named volumes persist unless you also remove
them), then delete the offline runner entry from GitHub → Settings → Actions →
Runners.
