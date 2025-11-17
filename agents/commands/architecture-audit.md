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