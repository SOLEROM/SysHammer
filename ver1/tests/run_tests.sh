#!/usr/bin/env bash
# run_tests.sh - Discovers and runs all test_*.sh files
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TOTAL_SUITES=0
PASSED_SUITES=0
FAILED_SUITES=0
FAILED_LIST=()

echo "========================================"
echo " Syshammer Test Suite"
echo "========================================"
echo ""

for test_file in "$TESTS_DIR"/test_*.sh; do
    [[ -f "$test_file" ]] || continue
    test_name=$(basename "$test_file" .sh)

    TOTAL_SUITES=$((TOTAL_SUITES + 1))
    echo "--- Running: $test_name ---"

    if bash "$test_file"; then
        PASSED_SUITES=$((PASSED_SUITES + 1))
    else
        FAILED_SUITES=$((FAILED_SUITES + 1))
        FAILED_LIST+=("$test_name")
    fi
    echo ""
done

echo "========================================"
echo " Results: $PASSED_SUITES/$TOTAL_SUITES suites passed"
if [[ $FAILED_SUITES -gt 0 ]]; then
    echo " Failed: ${FAILED_LIST[*]}"
fi
echo "========================================"

[[ $FAILED_SUITES -eq 0 ]]
