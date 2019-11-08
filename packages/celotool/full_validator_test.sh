#!/usr/bin/env bash
set -euo pipefail

# This test starts ione validator behind a proxy

# For testing a particular branch of Geth repo (usually, on Circle CI)
# Usage: full_validator_test.sh checkout <branch_of_geth_repo_to_test>
# For testing the local Geth dir (usually, for manual testing)
# Usage: full_validator_test.sh local <location_of_local_geth_dir>

if [ "${1}" == "checkout" ]; then
    # Test master by default.
    BRANCH_TO_TEST=${2:-"master"}
    echo "Checking out geth at branch ${BRANCH_TO_TEST}..."
    ../../node_modules/.bin/mocha -r ts-node/register src/e2e-tests/validator_tests.ts --branch ${BRANCH_TO_TEST}
elif [ "${1}" == "local" ]; then
    export GETH_DIR="${2}"
    echo "Testing using local geth dir ${GETH_DIR}..."
    ../../node_modules/.bin/mocha -r ts-node/register src/e2e-tests/validator_tests.ts --localgeth ${GETH_DIR}
fi
