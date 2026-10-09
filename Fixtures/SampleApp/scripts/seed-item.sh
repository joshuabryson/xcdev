#!/bin/sh
# The sample project's script route (`seeded`): a stand-in for a project's own way to reach a screen. A real one
# would put data in place first; this one restarts the sample app at the item it is asked for. xcd gives the
# route's values as XCD_PARAM_<NAME> and the worktree's context as XCD_* (`xcd context` prints those).
set -eu
echo "seeding item ${XCD_PARAM_ID} for route ${XCD_ROUTE} on ${XCD_DEVICE}"
xcrun simctl launch --terminate-running-process "$XCD_UDID" "$XCD_BUNDLE_ID" -startRoute "seeded/${XCD_PARAM_ID}"
