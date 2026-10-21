# 11: CI failures on agent MRs

**What to build:** Route failed pipelines on agent MRs to pipeline-doctor instead of building a separate fixer. See `../spec.md`.

**Blocked by:** 09

**Status:** needs-triage

- [ ] A failed pipeline on an agent MR triggers pipeline-doctor
- [ ] Non-agent MRs are not touched
