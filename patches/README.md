# ACP server patches

These patches carry the local ACP-server fixes on top of the official
`MoonshotAI/kimi-code` source. They are applied with `git apply` to the
source archive of `base.json`'s `upstreamTag`; nothing else from the fork is
needed.

| Patch | Upstream behavior it changes |
| --- | --- |
| `0001` | Coalesces streaming deltas into sentence-sized `agent_message_chunk` notifications, and serves writes under the agent home dir locally instead of through the ACP client. |
| `0002` | Emits `usage_update` after session setup, on model switch, and after compaction so Zed keeps the context-size indicator in sync. |
| `0003` | Reassembles slash-command arguments across interleaved text and `resource`/`resource_link` blocks, so `@file` mentions no longer truncate them. |

## Refreshing to a newer upstream version

1. Rebase the three commits from `opt/acp-server` onto the new upstream tag.
2. Regenerate the patches against that tag:
   ```sh
   git diff <base>..<fix1> -- packages/acp-server > patches/0001-....patch
   ```
3. Update `base.json` (`upstreamTag`, patch list).
4. Run the `Patch Native Release` workflow with the new tag; if a patch no
   longer applies, `git apply --check` fails the build with the offending
   file.

The workflow downloads the official source tarball and never clones the
fork, so CI length is bounded by the archive plus `pnpm install`.

## Triggering it

- **Manual**: Actions → `Patch Native Release` → Run workflow on this
  branch. Leave `tag` empty to build `base.json`'s `upstreamTag`.
- **Scheduled**: the daily run picks the newest stable upstream tag and
  skips versions whose patched release already exists. GitHub only runs
  schedules from the repository's default branch, so make this branch the
  default of the fork (or rely on manual dispatch).
