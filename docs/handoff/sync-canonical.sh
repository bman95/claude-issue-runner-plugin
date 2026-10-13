#!/bin/bash
cd /Users/vela/dev/sicma21/claude-issue-runner-plugin
rsync -a --exclude 'test-*.sh' --exclude 'agent-trace.sh' --exclude '.DS_Store' skills/ codex/issue-runner/canonical/
diff -rq skills codex/issue-runner/canonical | grep -v "test-\|agent-trace\|DS_Store"
