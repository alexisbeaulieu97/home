#!/bin/bash
#
# test_json_output.sh - Tests for JSON output functionality
#

# Simple test without framework dependencies
test_json_basic() {
    echo "Testing basic JSON output..."
    
    # Create a minimal config
    local config="/tmp/test_json_basic.json"
    cat > "$config" << 'EOF'
{
    "rules": [
        {
            "roots": "/tmp",
            "acl": ["u::rwx"]
        }
    ]
}
EOF
    
    # Test JSON output
    local output
    if ! output=$(./engine.sh -f "$config" --dry-run --output-format json 2>/dev/null); then
        echo "FAIL: JSON output command failed"
        return 1
    fi
    
    # Test that it's valid JSON
    if ! echo "$output" | jq . >/dev/null 2>&1; then
        echo "FAIL: Output is not valid JSON"
        echo "Output was: $output"
        return 1
    fi
    
    # Test required fields
    if ! echo "$output" | jq -e '.run' >/dev/null 2>&1; then
        echo "FAIL: Missing 'run' field"
        return 1
    fi
    
    if ! echo "$output" | jq -e '.config' >/dev/null 2>&1; then
        echo "FAIL: Missing 'config' field"
        return 1
    fi
    
    if ! echo "$output" | jq -e '.metrics' >/dev/null 2>&1; then
        echo "FAIL: Missing 'metrics' field"
        return 1
    fi
    
    echo "PASS: Basic JSON output test"
    return 0
}

test_text_vs_json() {
    echo "Testing text output suppression in JSON mode..."
    
    local config="/tmp/test_text_vs_json.json"
    cat > "$config" << 'EOF'
{
    "rules": [
        {
            "roots": "/tmp",
            "acl": ["u::rwx"]
        }
    ]
}
EOF
    
    # Get text mode output (should have INFO/SUCCESS messages on stderr)
    local text_output json_output
    text_output=$(./engine.sh -f "$config" --dry-run --output-format text 2>&1)
    
    # Get JSON mode output (should only have JSON on stdout, no INFO messages)
    json_output=$(./engine.sh -f "$config" --dry-run --output-format json 2>&1)
    
    # Check that JSON output contains valid JSON structure
    if ! echo "$json_output" | jq -e '.run' >/dev/null 2>&1; then
        echo "FAIL: JSON output doesn't contain valid JSON structure"
        return 1
    fi
    
    # Check that text output contains INFO messages but JSON output doesn't
    if ! echo "$text_output" | grep -q "INFO:"; then
        echo "FAIL: Text output should contain INFO messages"
        return 1
    fi
    
    if echo "$json_output" | grep -q "INFO:"; then
        echo "FAIL: JSON output should not contain INFO messages"
        return 1
    fi
    
    echo "PASS: Text output suppression test"
    return 0
}

# Run tests
echo "=== JSON Output Tests ==="
test_json_basic || exit 1
test_text_vs_json || exit 1
echo "=== All tests passed ==="