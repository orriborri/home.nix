# 04: Manual tracer bullet

**What to build:** Take one small real Linear issue through the whole flow by hand. Run the planner, then `claude -p --model claude-haiku-5-5 --output-format json` on one resulting ticket. See `../spec.md`.

**Blocked by:** 01, 02, 03

**Status:** needs-triage

- [ ] Tokens and cost per stage recorded from the JSON output
- [ ] Recorded: did the TDD loop hold, and where did the agent get lost
- [ ] A real token cap replaces the 80k guess
- [ ] Findings written to `## Comments` here; they shape 05–09
