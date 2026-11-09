# ACP server patches

These patches carry the local ACP-server fixes on top of the official
`MoonshotAI/kimi-code` source. They are applied with `git apply` to the
source archive of the latest upstream stable release; nothing else from the
fork is needed.

| Patch | Upstream behavior it changes |
| --- | --- |
| `0001` | Coalesces streaming deltas into sentence-sized `agent_message_chunk` notifications, and serves writes under the agent home dir locally instead of through the ACP client. |
| `0002` | Emits `usage_update` after session setup, on model switch, and after compaction so Zed keeps the context-size indicator in sync. |
| `0003` | Reassembles slash-command arguments across interleaved text and `resource`/`resource_link` blocks, so `@file` mentions no longer truncate them. |

## Zed npx cache bundle

The workflow publishes per-platform cache bundles for Zed's npx registry
cache, plus a `.sha256` and a per-platform `kimi-code-zed-cache-<platform>.json`
manifest:

- Linux: `kimi-code-zed-cache-<platform>-<version>-patched.tar.gz`
- Windows: `kimi-code-zed-cache-<platform>-<version>-patched.zip`

Each bundle contains the complete `npx/kimi-code` install tree (patched
`dist/main.mjs`, lockfiles, `node_modules`, `.bin` shims), so no local
`npm install` is needed.

On Linux:

```sh
scripts/update-zed-cache.sh              # newest v<version>-patched release
scripts/update-zed-cache.sh --dry-run    # download and validate only
```

On Windows:

```powershell
.\scripts\update-zed-cache.ps1
.\scripts\update-zed-cache.ps1 -DryRun
```

Close the `kimi-code` agent before running the Windows script; Windows may
refuse to rename a cache directory whose files are still open. The Windows
script updates `%LOCALAPPDATA%\Zed\external_agents\registry\npx\kimi-code`
by default; pass `-CacheDir` to override it. If the execution policy blocks
the script, run it with
`powershell -ExecutionPolicy Bypass -File .\scripts\update-zed-cache.ps1`.

The scripts verify the checksum and patch markers, refuse to downgrade a
cache that Zed has moved to another version, swap the tree atomically, and
remove the previous tree after a successful swap. Restart the `kimi-code`
agent in Zed afterwards.

Scheduled runs skip releases that already exist. To add cache assets to an
existing `v<version>-patched` release, dispatch the workflow manually.

## Refreshing to a newer upstream version

1. Rebase the three commits from `opt/acp-server` onto the new upstream tag.
2. Regenerate the patches against that tag:
   ```sh
   git diff <base>..<fix1> -- packages/acp-server > patches/0001-....patch
   ```
3. Run the `Patch Native Release` workflow. The resolve job applies every
   patch to the freshly downloaded upstream archive; if any `git apply
   --check` fails, the workflow stops before any build job starts.

The workflow downloads the official source tarball and never clones the
fork, so CI length is bounded by the archive plus `pnpm install`.

## Triggering it

- **Manual**: Actions → `Patch Native Release` → Run workflow on this
  branch. Leave `tag` empty to build the latest upstream stable release;
  set it only to rebuild a specific version.
- **Scheduled**: the daily run also picks the latest stable upstream
  release and skips versions whose patched release already exists. GitHub
  only runs schedules from the repository's default branch, so make this
  branch the default of the fork (or rely on manual dispatch).
