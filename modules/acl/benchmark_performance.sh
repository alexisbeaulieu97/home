#!/bin/bash
#
# benchmark_performance.sh - Demonstrate ACL performance optimization
#

set -euo pipefail

# Colors for output
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly YELLOW='\033[1;33m'
readonly RESET='\033[0m'

echo "=== ACL Engine Performance Optimization Benchmark ==="
echo

# Create test directory with many files
TEST_DIR="/tmp/acl_benchmark_$$"
echo "Creating test directory with 50 files and subdirectories..."
mkdir -p "$TEST_DIR"/{dir1,dir2,dir3}/{subdir1,subdir2}

for i in {1..50}; do
    dir_num=$((i % 3 + 1))
    subdir_num=$((i % 2 + 1))
    echo "content $i" > "$TEST_DIR/dir$dir_num/subdir$subdir_num/file$i.txt"
done

echo "Created directory structure with $(find "$TEST_DIR" -type f | wc -l) files"
echo

# Config without filters (uses optimization)
OPTIMIZED_CONFIG="$TEST_DIR/optimized.json"
cat > "$OPTIMIZED_CONFIG" << EOF
{
  "version": "1.0",
  "rules": [
    {
      "id": "optimized-benchmark",
      "roots": ["$TEST_DIR"],
      "recurse": true,
      "include_self": true,
      "acl": {
        "files": [{"kind": "group", "name": "users", "mode": "rw-"}],
        "directories": [{"kind": "group", "name": "users", "mode": "rwx"}]
      }
    }
  ]
}
EOF

# Config with filters (uses individual processing)
INDIVIDUAL_CONFIG="$TEST_DIR/individual.json"
cat > "$INDIVIDUAL_CONFIG" << EOF
{
  "version": "1.0",
  "rules": [
    {
      "id": "individual-benchmark",
      "roots": ["$TEST_DIR"],
      "recurse": true,
      "include_self": true,
      "match": {
        "types": ["file", "directory"],
        "pattern_syntax": "glob",
        "include": ["**/*"],
        "exclude": []
      },
      "acl": {
        "files": [{"kind": "group", "name": "users", "mode": "rw-"}],
        "directories": [{"kind": "group", "name": "users", "mode": "rwx"}]
      }
    }
  ]
}
EOF

echo -e "${BLUE}Testing OPTIMIZED approach (no filters):${RESET}"
time_start=$(date +%s.%N)
optimized_output=$(./engine.sh -f "$OPTIMIZED_CONFIG" --dry-run 2>&1)
time_end=$(date +%s.%N)
optimized_time=$(echo "$time_end - $time_start" | bc -l 2>/dev/null || awk "BEGIN {print $time_end - $time_start}")

echo "$optimized_output" | grep -E "(Using optimized|setfacl|Summary)"
echo -e "${GREEN}Time: ${optimized_time}s${RESET}"
echo

echo -e "${BLUE}Testing INDIVIDUAL approach (with filters):${RESET}"
time_start=$(date +%s.%N)
individual_output=$(./engine.sh -f "$INDIVIDUAL_CONFIG" --dry-run 2>&1)
time_end=$(date +%s.%N)
individual_time=$(echo "$time_end - $time_start" | bc -l 2>/dev/null || awk "BEGIN {print $time_end - $time_start}")

echo "$individual_output" | grep -E "(SUCCESS|Summary)" | tail -5
echo -e "${GREEN}Time: ${individual_time}s${RESET}"
echo

# Calculate performance improvement
if command -v bc >/dev/null 2>&1; then
    improvement=$(echo "scale=2; $individual_time / $optimized_time" | bc -l)
    echo -e "${YELLOW}Performance improvement: ${improvement}x faster${RESET}"
else
    echo -e "${YELLOW}Optimized approach completed in ${optimized_time}s vs ${individual_time}s for individual approach${RESET}"
fi

# Count setfacl commands
optimized_cmds=$(echo "$optimized_output" | grep -c "setfacl" || true)
individual_cmds=$(echo "$individual_output" | grep -c "setfacl" || true)

echo -e "${YELLOW}setfacl commands: Optimized=$optimized_cmds, Individual=$individual_cmds${RESET}"
echo

# Cleanup
rm -rf "$TEST_DIR"

echo "=== Benchmark Complete ==="
echo "The optimization reduces both execution time and the number of setfacl system calls,"
echo "providing significant performance improvements for large directory trees."