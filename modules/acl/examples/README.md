# ACL Configuration Examples

This directory contains working examples of ACL configurations to help you get started quickly.

## 📁 Files

### **Working Examples**
- `working_minimal.json` - Simplest working configuration
- `clean_example_1.json` - Complex multi-rule configuration (clean version)
- `minimal.json` - Minimal configuration template
- `test.json` - Simple test configuration
- `example_1.json` - Complex example with file/directory-specific ACLs
- `example_2.json` - Advanced example with multiple rule types

## 🚀 Quick Start

### **Test a Working Example**
```bash
# Test minimal configuration
./engine.sh -f examples/working_minimal.json --dry-run

# Test complex configuration  
./engine.sh -f examples/clean_example_1.json --dry-run
```

### **Validate Your Configuration**
```bash
# Basic JSON validation
jq . your_config.json

# Validate against the schema (requires ajv-cli or similar)
# Install: npm install -g ajv-cli
ajv validate -s ../schemas/schema.json -d your_config.json
```

## 🔍 Format Comparison

### **Current Format (Recommended)**
```json
{
  "rules": [
    {
      "roots": "/path/to/directory",
      "recurse": true,
      "include_self": true,
      "acl": ["g:groupname:rwx"]
    }
  ]
}
```

**Pros:** Concise, POSIX-aligned, flexible
**Cons:** Learning curve, less self-documenting

## 💭 Discussion Points

1. **Learning Curve vs. Readability** - Is POSIX ACL syntax acceptable?
2. **Verbosity vs. Clarity** - How much detail do you need?
3. **Validation** - How important is automatic validation?
4. **Team Collaboration** - Who will maintain these configs?
5. **Future Evolution** - How might requirements change?

## 📋 Next Steps

1. **Test current format** with your team
2. **Review alternatives** in `schemas/format_analysis.md`
3. **Discuss trade-offs** based on your specific needs
4. **Prototype changes** if needed
5. **Gather feedback** from actual users

## 🔧 Schema Validation

The `schemas/schema.json` file provides comprehensive validation for:
- Required vs. optional fields
- Data type validation
- Pattern matching for permissions
- Cross-field validation rules
- Default values and constraints

Use it to validate your configurations and catch errors early.

## 📚 Schema Documentation

For detailed analysis of different format approaches and alternative proposals, see the `schemas/` directory:
- `schemas/schema.json` - Complete JSON schema for validation
- `schemas/format_analysis.md` - Detailed analysis of different format approaches
- `schemas/format_comparison.json` - Side-by-side comparison of formats
- `schemas/alternative_format.json` - More structured, explicit format proposal
