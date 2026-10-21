---
name: implement-ticket
description: Implement an analyzed Linear ticket from its todo.md, simplest task first, red → green → refactor → review per task.
disable-model-invocation: true
---

# Implement a ticket

Input: a ticket ID, e.g. `/implement-ticket RP-123`. Work happens in
`~/workspace/<TICKET>/`. Its `analysis.md` (written by `analyze-ticket`) is
the input; `todo.md` there is the ticket's tracker and the single source of
truth for what is done.

If `analysis.md` is missing, stop and say: run `launch-ec2 analyze <TICKET>`
first. If `todo.md` already exists, this is a resume: skip to the loop.

## The tracker: todo.md

```markdown
# <TICKET>: <title>

## Tasks
- [ ] T1 <one behaviour, imperative> | repo: <repo> | seam: <public interface the test drives> | verify: <command> | size: S | after: -
- [~] T2 ...                       (in progress; at most one)
- [x] T3 ... — <commit hash>
- [-] T4 ... — blocked: <exact reason>

## DAG
<mermaid graph, one edge per ordering need, labelled with its reason>

## Packages
<package: tasks, goal, done-when check>

## Coverage
<each acceptance criterion and each affected item from analysis.md → task IDs>

## Log
<one entry per task: order chosen, red output, refactor, review>

## Out of scope
<findings that belong to another ticket>

## MRs
<one line per repo: repo | branch | MR URL>
```

Size: S under 30 min, M a few hours, L a day. An L is a sign the task can
be split further; split it.

## 1. Break down

Turn `analysis.md` into the smallest tasks possible. A task is one
behaviour, one commit, one `verify` command, one seam. It cannot be split
further without leaving the repo broken between the pieces. Investigation
is a task too.

Clone each repo the tasks touch: `git clone /var/lib/code/readpeak/<repo>`,
then `git remote set-url origin git@gitlab.com:readpeak/<repo>.git`, then
`git switch -c <branch>`. `<branch>` is the ticket's Linear `gitBranchName`
from `analysis.md`, used exactly: that name is what links the MR to the
ticket. If `analysis.md` lacks it, use `<ticket-lowercase>-<slug>`. Read the repo's `AGENTS.md` /
`CLAUDE.md` and find its test command before writing tasks against it.

Done when the Coverage section maps every acceptance criterion and every
affected item in `analysis.md` to at least one task.

## 2. DAG and packages

Add an edge A → B only when order matters, with one reason: *blocks* (B is
impossible or wrong before A), *same-file* (both edit the same lines),
*verifies* (A provides B's check), *decides* (A's outcome changes B). Group
tasks that share files or one verification run into packages.

Done when every `after:` matches the DAG and the DAG has no cycle.

## 3. Plan gate

Show the human the Tasks, DAG and seams, and wait for approval. The seams
listed here are the agreed seams the `tdd` skill asks for; no test is
written at a seam outside this list. Record the approval in the Log.

## 4. Loop

Repeat until no `[ ]` task is unblocked.

### Pick the simplest

List every `[ ]` task whose `after:` tasks are all `[x]`. Sort them simplest
first: size (S < M < L), then fewer files touched, then lower ID. Take the
first, mark it `[~]`, and write the sorted list in the Log. Re-sort every
iteration: review findings and new knowledge change the order.

Note the task's start commit: `git rev-parse HEAD`.

### Red

Write one test at the task's seam for the task's behaviour, following the
`tdd` skill. Run it. It must fail for the reason the task names; paste the
failing line in the Log. A test that passes at once proves nothing: fix the
test or record why the behaviour already exists and mark the task `[x]`.

### Green

Write the least code that makes the test pass. Run the test, then the
repo's full test command. Both pass.

### Refactor

Refactor is a required step of every cycle; this skill overrides the `tdd`
skill's rule that refactoring sits outside the loop. With the tests green,
inspect the code this task touched for: duplication, names that no longer
fit, dead code or comments the change made stale, functions that grew past
one job. Fix what you find, keeping behaviour the same, and rerun the tests.

Done when the Log has a `refactor:` line naming each change made, or
`refactor: none` followed by what was inspected and why it is already clean.
Tests are green afterwards.

### Review

Run the `code-review` skill with the task's start commit as the fixed point.
Every finding, including notes and untested edge cases, lands in exactly one
place: a new `[ ]` task in todo.md (with `from: review T<n>`) when it is in
this ticket's scope, Out of scope when it is not, or a question to the human
when the ticket does not say which.

### Commit

One commit per task in that repo: Conventional Commit subject, body naming
the task ID and its test, footer `Refs: <TICKET>`. Mark the task
`[x] … — <hash>`. If the task needs credentials, a deploy, or a human
decision, mark it `[-] blocked: <exact reason>` instead and pick the next.

## 5. Finish

Done when every task is `[x]` or `[-]`, every repo's full test command
passes, and every repo's working tree is clean.

## 6. Push and open the MR

For each repo with commits on `<branch>`:

1. `git push -u origin <branch>`. The target is always the ticket branch;
   `main` is protected and the token cannot merge.
2. Create the MR with the command in `~/.claude/CLAUDE.md` ("Push and merge
   requests"), with:
   - title: `<type>(<scope>): <summary> (<TICKET>)`
   - description, starting with the magic word line that links the ticket:

     ```
     Fixes <TICKET>

     ## Tasks
     <each [x] task: ID, title, commit hash>

     ## Tests
     <each command run in this repo and its result>

     ## Blocked / out of scope
     <each [-] task with its reason; each Out of scope item>
     ```
3. Write `repo | branch | MR URL` under MRs in todo.md.

Done when every repo with commits has an MR line in todo.md. Report in
under 10 lines: the MR URLs, tasks blocked with reasons, and Out of scope
items.
