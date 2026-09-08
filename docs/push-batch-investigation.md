# Push batch lifecycle investigation

Original failure: main commit 6e24bcbead3d352f305fb92bee9d894de441f554, run 34237080747, Debian full-suite context.
The partial-transfer case entered lifecycle failure before the following batch failed accounting.

Current probes require exact ordinary failure status and preserve lifecycle barriers. Eight fixed rounds stop on the first failure; no retry-to-green.
Selective push-only runs have not reproduced the original failure. This document is an unknown dependency under the existing tests/run.sh mapping, intentionally exercising the existing full-suite fallback for this diagnostic PR. No workflow or selection rules are changed.

Capture only Bash version, return codes and lifecycle maps. No credentials, full environment dump or global xtrace.
A green full run is not proof of a fix. Retain original logs and distinguish fixture instrumentation from production behavior.

Next evidence needed: first failing boundary and pre-teardown state under the full suite. Production code remains unchanged; PR 47 stays blocked pending an explained resolution.
