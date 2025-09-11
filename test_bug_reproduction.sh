#!/bin/bash

# Simple test to reproduce the bug described in the issue
# Bug: directory files not included when recurse is set to false

set -euo pipefail

cd /home/runner/work/home/home/modules/acl

# Create test directory structure
TEST_DIR="/tmp/test_recurse_bug"
rm -rf "$TEST_DIR"
mkdir -p "$TEST_DIR"

# Create files and subdirectories
touch "$TEST_DIR/file1.txt"
touch "$TEST_DIR/file2.log"
mkdir -p "$TEST_DIR/subdir"
touch "$TEST_DIR/subdir/nested_file.txt"

echo "Test directory structure:"
find "$TEST_DIR" -ls

# Source the engine functions to test them directly
ENGINE_SCRIPT="./engine.sh"
cp "$ENGINE_SCRIPT" "test_engine_bug.sh"
# Comment out the main execution to avoid running the full script
sed -i 's/^if \[\[ "${BASH_SOURCE\[0\]}" == "${0}" \]\]; then/# &/' "test_engine_bug.sh"
sed -i 's/^    main "\$@"/# &/' "test_engine_bug.sh" 
sed -i 's/^fi$/# &/' "test_engine_bug.sh"

# Source the engine
source "./test_engine_bug.sh"

# Initialize minimal config
declare -A CONFIG=(
    [find_optimization]="true"
)

echo ""
echo "=== Testing enumerate_paths_simple with recurse=false ==="
echo "Expected: Should include $TEST_DIR and files directly inside it"
echo "Actual result:"
enumerate_paths_simple "false" "true" "$TEST_DIR"

echo ""
echo "=== Testing enumerate_paths_simple with recurse=true ==="
echo "Expected: Should include all files and directories recursively"
echo "Actual result:"
enumerate_paths_simple "true" "true" "$TEST_DIR"

# Clean up
rm -rf "$TEST_DIR"
rm -f "test_engine_bug.sh"