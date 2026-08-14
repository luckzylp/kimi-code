---
"@moonshot-ai/kimi-code": patch
---

Fix slash-command arguments being truncated when file references are inlined mid-command, so `/skill:foo 请看 @a.ts 前面 参考 @b.ts …` now passes the full argument text to the skill.