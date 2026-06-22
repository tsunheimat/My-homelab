# Vendored Coder modules

Single source of truth for the patched Coder app modules used by the templates under
`coder/templates/`. Each module here is **pristine upstream [`coder/registry`](https://github.com/coder/registry)
plus one tiny patch**: an `icon` input variable wired into `coder_app.icon`, so the Workspaces
app buttons show custom icons. Upstream hard-codes `icon = "/icon/code.svg"` and exposes no
icon input, which is the only reason these are vendored.

| Module | Upstream | Why vendored |
|---|---|---|
| `code-server` | `release/coder/code-server/v1.5.0` | adds `variable "icon"` → `coder_app.icon` |
| `vscode-web`  | `release/coder/vscode-web/v1.5.1`  | adds `variable "icon"` → `coder_app.icon` |

`vscode-desktop-core` is **not** vendored — upstream already exposes `coder_app_icon`, so the
template consumes the registry module directly.

## How templates consume these

Over a git source (so `coder templates push` works — local `../` paths outside the template
dir are not uploaded in the push tarball):

```hcl
module "vscode-web" {
  source = "git::https://github.com/tsunheimat/My-homelab.git//coder/modules/vscode-web?ref=main"
  icon   = local.vscode_web_icon
  # ...
}
```

`?ref=main` re-resolves to current `main`. For hard reproducibility, pin `?ref=` to a tag or
commit SHA and bump it deliberately.

## Layout

```
coder/modules/<name>/
  main.tf          # pristine upstream + icon patch applied
  run.sh           # pristine upstream (unchanged)
  UPSTREAM_REF     # the coder/registry tag this was vendored from
coder/patches/
  <name>-icon.patch  # the minimal icon-only diff (≈ +8 / -2 lines)
```

## Maintenance (automated)

`.github/workflows/sync-coder-modules.yml` runs weekly (and on demand). Per module it:

1. discovers the latest `release/coder/<name>/v*` tag on `coder/registry`,
2. re-vendors the **pristine** upstream files (overwriting this dir),
3. re-applies `coder/patches/<name>-icon.patch`,
4. runs `terraform validate`,
5. opens a PR.

Renovate (`renovate.json`) separately bumps the `vscode-desktop-core` registry `version` and
GitHub Action versions.

### When you (the maintainer) act

- **Sync PR is green** → merge; you're current.
- **Sync job fails on `git apply`** → upstream refactored the icon area. Re-vendor by hand,
  re-apply the change, regenerate the patch:
  ```bash
  # from a checkout of the new upstream tree vs the patched main.tf
  git diff > coder/patches/<name>-icon.patch
  ```
  then commit.
- **Upstream adds its own icon input** (likely `coder_app_icon`, like vscode-desktop-core) →
  retire the fork: delete this dir + the patch, point the template at
  `registry.coder.com/coder/<name>/coder` with `version =` and the upstream icon argument.

## Regenerating a patch from scratch

The patch is just: insert a `variable "icon"` block (default `/icon/code.svg`) before
`variable "slug"`, and replace the two `icon = "/icon/code.svg"` lines with `icon = var.icon`.
