<!-- context7 -->
Use the Context7 plugin for current or version-specific external documentation about libraries, frameworks, SDKs, APIs, CLIs, and cloud services. For repository-specific behavior, inspect existing code, lockfiles, and installed types first. Do not use Context7 for refactoring, new scripts, business-logic debugging, code review, or general programming concepts.

1. Resolve the exact library/version unless the user provided its `/org/project` ID.
2. Query docs with the full question and keep the request focused on the decision at hand.
3. Prefer Context7 over web search for library documentation.
<!-- context7 -->


## AWS execution approval

Before every AWS command or AWS API operation, show the exact command or operation, target account/profile and region, and whether it reads or changes resources. Wait for explicit user approval for that command or a clearly listed batch. This includes read-only checks and calls through SDKs, scripts, subprocesses, CDK/Terraform, remote execution, connectors, or browser actions. General requests to investigate or fix something are not execution approval. Preparing local code and reading public documentation are allowed. Never use another tool or wrapper to bypass this approval requirement.


## Token efficiency

- Search narrowly and read only relevant files or line ranges; reuse findings unless files may have changed.
- Inspect one or two close examples before adding a new package, service, or CI pattern.
- Filter large command output at the source; avoid duplicate searches, MCP calls, and unchanged validation runs.
- Prefer repository code and installed types for local behavior; use current external docs for version-sensitive APIs.
