Excellent, let's finalize the command.

Based on recent prompting guides for advanced models like GPT-5-Codex, the core principle is "less is more." These models have many best practices built-in, and overly prescriptive prompts can sometimes reduce the quality of the output. The goal is to provide high-level, clear instructions and trust the model's specialized training.

This final version is refined to be as generic and powerful as possible, aligning with these advanced prompting strategies.

### The Generic, Reusable Command for Code Architecture Audits

This command is designed to be used "as-is." You would provide the entire codebase as the context for this prompt.

```
Act as an expert software architect.

You will be provided with a codebase for a software project. Your task is to conduct a thorough audit of its architecture. Your goal is to provide actionable insights to improve its overall quality, maintainability, scalability, and security.

**Guiding Checklist for Analysis:**
Use the following list as a mental model for potential areas of improvement. Your suggestions should be inspired by these points, but your primary goal is to identify the most significant architectural issues. I trust your expertise to look beyond this list.

#### **Maintainability & Readability**
*   **Duplicate Code:** Redundant code that can be consolidated.
*   **Unclear Naming:** Ambiguous or inconsistent names for variables, functions, or classes.
*   **Overly Complex Components:** Functions or classes that are too large, have too many responsibilities ("God Objects"), or have long parameter lists.
*   **Dead Code:** Unused or unreachable code.
*   **Hardcoded Values:** "Magic numbers" or strings that should be constants.

#### **Architectural & Design Patterns**
*   **Separation of Concerns:** Improper mixing of logic (e.g., UI, business logic, data access).
*   **High Coupling:** Modules are too dependent on each other, making changes difficult.
*   **Low Cohesion:** Elements within a single module are unrelated.
*   **Data Clumps:** Groups of variables are passed around together instead of being encapsulated in an object.
*   **Primitive Obsession:** Over-reliance on basic data types instead of creating specific value objects.

#### **Performance & Scalability**
*   **Inefficient Database Queries:** Issues like N+1 problems, queries inside loops, or fetching excessive data.
*   **Lack of Caching:** Opportunities to cache frequently accessed, slow-to-retrieve data.
*   **Blocking Operations:** Synchronous I/O that could be made asynchronous to improve throughput.
*   **Missing Pagination:** Failure to paginate when retrieving large data sets.

#### **Security**
*   **Injection Vulnerabilities:** Risks of SQL, command, or other injection attacks.
*   **Improper Secret Management:** Storing credentials or API keys insecurely.
*   **Lack of Input Validation:** Failure to properly sanitize and validate all external input.
*   **Insecure Direct Object References:** Exposing internal identifiers that could be manipulated.

#### **Error Handling & Observability**
*   **Swallowing Exceptions:** Catching exceptions without logging or re-throwing them, which hides bugs.
*   **Overly Broad Exception Handling:** Generic `catch` blocks that obscure the specific nature of an error.
*   **Inadequate Logging:** Insufficient or unstructured logging, making debugging difficult.

**Your Output:**
For each significant area you identify as needing improvement, provide a "Transformation Suggestion." Structure your response as follows:

*   **Area for Improvement:** A brief description of the identified issue.
*   **Suggested Transformation:** A specific action (e.g., "Refactor," "Redo," "Improve," "Extract Microservice").
*   **Justification:** A clear explanation of why this transformation is beneficial.
*   **High-Level Implementation Steps:** A summary of the key steps to execute the transformation.
*   **Confidence Score:** Your confidence (as a percentage) that this suggestion provides high value.

**Filtering Rule:**
Crucially, only include suggestions with a **Confidence Score of 80% or higher.**
```

### Why This Version Aligns with Best Practices:
*   **Minimalist & High-Level:** The introduction is direct and avoids fluff. The checklist is presented as a "mental model" rather than a rigid set of instructions, respecting the model's built-in expertise.
*   **Clear Role and Goal:** It starts by assigning a persona ("expert software architect") and stating a clear objective. This is a fundamental best practice.
*   **Structured for Clarity:** The use of Markdown headers and bullet points clearly separates the different parts of the request (Goal, Checklist, Output Format, Rule). This helps the model parse the instructions accurately.
*   **Action-Oriented & Structured Output:** It explicitly defines the desired output format, which is critical for getting consistent, usable results.
*   **Self-Correction Mechanism:** The confidence score and filtering rule are advanced techniques that force the model to perform a self-assessment, significantly improving the quality and relevance of the final suggestions.
*   **Generic and Reusable:** By removing all project-specific placeholders, this command can be saved and applied to any codebase by simply providing the code as context.