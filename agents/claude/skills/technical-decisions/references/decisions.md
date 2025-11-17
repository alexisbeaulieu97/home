# Technical Decisions Reference

This skill works with the project's technical decisions registry.

## Where to Put The Project's Decision Registry

Each project should maintain a decisions registry file in this location: `@/docs/decisions.md`

**To view all decisions**, look for the decisions registry file in the project.

## Decision Structure

Each decision in the registry should include:

- **ID**: Unique identifier for citing the decision (e.g., `decision-id`, kebab-case)
- **Category**: Domain of the decision (e.g., Architecture, Testing, Code Style)
- **Context**: Why the decision was made and what problem it solves
- **Decision**: The actual rule, pattern, or constraint
- **Constraints & Tradeoffs**: Analysis of pros/cons and accepted tradeoffs
- **Examples**: ✅ Correct approaches and ❌ incorrect approaches with code
- **Related Decisions**: Cross-references to complementary decisions

Example:

```
### Decision: [Title]

**ID**: `unique-id-for-citing`
**Category**: Category Name
**Last Updated**: YYYY-MM-DD

**Summary**
Brief one-sentence summary of the decision.

**Context**
Why was this decision made? What problem does it solve?

**Decision**
The actual rule or pattern.

**Constraints & Tradeoffs**
- **Pro**: Benefits of this decision
- **Con**: Drawbacks or costs
- **Tradeoff accepted**: Why the tradeoff is worth it

**Examples**
✅ **Use**: [correct code/approach]
❌ **Avoid**: [incorrect code/approach]

**Related Decisions**
- `decision-id-1`
- `decision-id-2`
```

## Common Decision Categories

Projects often organize decisions into categories like:
- **Architecture**: System design, module organization, patterns
- **Code Style**: Naming conventions, formatting, structure
- **Testing**: Testing strategy, coverage requirements, doubles vs mocks
- **Data & Models**: Model design, serialization, validation
- **Error Handling**: Exception hierarchy, error messages
- **Configuration**: Settings management, environment variables
- **Performance**: Optimization patterns, caching strategies
- **Security**: Authentication, authorization, validation patterns
- **Documentation**: Comment style, documentation requirements

## Creating The Registry

If the project doesn't have a decisions registry yet:
1. Create `docs/decisions.md` in the project
2. Organize decisions by category
3. Include a summary table for quick reference
