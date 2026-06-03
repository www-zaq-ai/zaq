---
description: Focuses on precisely covering up code files with tests by leveraging dedicated skills
---

When development work is produced, new lines that aren't covered by a test can be introduced. Your goal is to identify these lines for all matching files and get them covered by automated tests (unit or integration)

## PROCESS

You have two main operating modes, you choose based on how you have been prompted:

### User provided file names with missed lines to cover

Skip steps 1 and 2 and go directly to step 3

### User only instructed to proceed

Follow these steps:
1 - Run `ls -lT cover/excoveralls.json` to check if the file is more than 24h old: if yes report back to the user and ask for a confirmation to proceed, otherwise continue
2 - Run `mix coverup` to get a report of all files changed that have a coverage below 95% with their respective uncovered line numbers
3 - For EACH file listed, spawn a general-purpose Agent with the `/test-coverage-planner` skill to generate one clear plan per file — pass it the file name and the uncovered lines
4 - Review all the plans to identify the ones overlapping similar test files and merge these (do NOT summarize any plan, just merge where fit) to produce a final set of fully detailed plans where no two plans touch the same test file
5 - For every ready plan, spawn a general-purpose Agent with the `/test-coverage-fixer` skill and pass it the full plan (no summary) to develop the code
6 - While agents are working, as soon as one is done, review its work and if there is anything wrong, follow up with it to get the job done. If all is good wait for the other agents to finish
7 - Once all agents are done run `mix q`, if there are errors reported you are in charge of producing a detailed plan to fix them. Once the plan is ready hand it over as-is to a new general-purpose Agent with the `/test-coverage-fixer` skill for implementation
8 - Finally report the new coverage of the targeted files by running `mix test {test_file_1} {test_file_2} .. {test_file_n} --cover` for added/edited test files only. Use `grep` to filter the output for relevant file coverage. Even if new coverage seems unchanged, report back with your observation and stop

## DO NOT

- Resort to doing the work of agents yourself — if they are blocked, report back
- Shorten the plans you receive before you hand them to the test-coverage-fixer agent — it needs as much detail as can possibly be provided
- Run the full test suite to re-assess coverage — an approximation based on step 8 is enough

## Summary

<1-3 sentences>

## Findings or Changes

- <bullet>
- <bullet>
