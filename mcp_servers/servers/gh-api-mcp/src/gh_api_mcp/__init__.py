import subprocess
from subprocess import CompletedProcess
from mcp.server.fastmcp import FastMCP
import base64
import json
from functools import wraps

# Create an MCP server
mcp = FastMCP("gh-api-mcp")


def run_gh_api_command(args: list[str], check: bool = True) -> CompletedProcess[str]:
    return subprocess.run(["gh", "api"] + args, capture_output=True, check=check)


def gh_command_exists() -> bool:
    return run_gh_api_command(["--version"], check=False).returncode == 0


def is_authenticated() -> bool:
    return subprocess.run(["gh", "auth", "status"], check=False).returncode == 0


def require_auth(fn):
    @wraps(fn)
    def wrapper(*args, **kwargs):
        if not is_authenticated():
            return "Error: User is not authenticated"
        return fn(*args, **kwargs)
    return wrapper


def _get_default_branch(owner: str, repo: str) -> str | None:
    try:
        result = run_gh_api_command([f"repos/{owner}/{repo}"])
    except subprocess.CalledProcessError:
        return None
    try:
        repo_data = json.loads(result.stdout)
        return repo_data.get("default_branch")
    except Exception:
        return None


@mcp.tool()
@require_auth
def list_tree(owner: str, repo: str, ref: str | None = None, path: str | None = None, include: str = "all") -> str:
    """
    List the tree of a repository.

    Args:
        owner: The owner of the repository.
        repo: The name of the repository.
        ref: The ref to list the tree of. Defaults to the default branch of the repository.
        path: The path to list the tree of. Defaults to the root of the repository.
        include: The type of entries to include. Defaults to all. Possible values are "all", "files", and "dirs".

    Returns:
        A JSON object with the tree of the repository.
    """

    resolved_ref = ref
    if not resolved_ref:
        resolved_ref = _get_default_branch(owner, repo) or "main"

    try:
        result = run_gh_api_command([
            f"repos/{owner}/{repo}/git/trees/{resolved_ref}",
            "--method", "GET",
            "-F", "recursive=1",
        ])
    except subprocess.CalledProcessError as e:
        return f"Error running gh command: {e.stderr}"

    try:
        data = json.loads(result.stdout)
    except json.JSONDecodeError as e:
        return f"Error decoding JSON: {e}"

    if "tree" not in data:
        return json.dumps({"error": "No tree in response", "raw": data})

    entries = data["tree"]

    if path:
        prefix = path.lstrip("/")
        entries = [e for e in entries if e.get("path", "").startswith(prefix)]

    if include == "files":
        entries = [e for e in entries if e.get("type") == "blob"]
    elif include == "dirs":
        entries = [e for e in entries if e.get("type") == "tree"]

    mapped: list[dict[str, str | int]] = []
    for e in entries:
        if e.get("type") == "tree":
            mapped.append(
                {
                    "path": e.get("path"),
                    "type": "directory",
                }
            )
        else:
            mapped.append(
                {
                    "path": e.get("path"),
                    "type": "file",
                    "bytes": e.get("size"),
                }
            )

    response = {
        "ref": resolved_ref,
        "count": len(mapped),
        "entries": mapped,
    }
    return json.dumps(response)


@mcp.tool()
@require_auth
def read_file(owner: str, repo: str, path: str, ref: str | None = None, raw: bool = False) -> str:
    """
    Read the contents of a file in a repository.

    Args:
        owner: The owner of the repository.
        repo: The name of the repository.
        path: The path to the file to read.
        ref: The ref to read the file from. Defaults to the default branch of the repository.
        raw: Whether to return the raw contents of the file. Defaults to False.

    Returns:
        The contents of the file.
    """

    if not path.startswith("/"):
        path = "/" + path

    try:
        if raw:
            # Request raw bytes for the file content; include ref when provided
            api_path = f"repos/{owner}/{repo}/contents/{path}"
            if ref:
                api_path = f"{api_path}?ref={ref}"
            result = run_gh_api_command([
                "-H", "Accept: application/vnd.github.raw",
                api_path,
            ])
            # Directly return raw text (utf-8, replacement on errors)
            stdout = result.stdout
            if isinstance(stdout, bytes):
                return stdout.decode("utf-8", errors="replace")
            return str(stdout)

        # Structured response that includes base64-encoded content
        api_path = f"repos/{owner}/{repo}/contents/{path}"
        if ref:
            api_path = f"{api_path}?ref={ref}"
        result = run_gh_api_command([api_path])
    except subprocess.CalledProcessError as e:
        return f"Error running gh command: {e.stderr}"

    try:
        data = json.loads(result.stdout)
    except json.JSONDecodeError as e:
        return f"Error decoding JSON: {e}"

    try:
        content_b64 = data.get("content")
        if content_b64 is None:
            # Fallback: try raw download if available
            download_url = data.get("download_url")
            if download_url:
                try:
                    raw_result = run_gh_api_command([
                        "-H", "Accept: application/vnd.github.raw",
                        download_url,
                    ])
                    stdout = raw_result.stdout
                    if isinstance(stdout, bytes):
                        return stdout.decode("utf-8", errors="replace")
                    return str(stdout)
                except subprocess.CalledProcessError as e:
                    return f"Error fetching raw content: {e.stderr}"
            return "Error: No 'content' key found in response"

        # Respect the reported encoding when present
        encoding = data.get("encoding")
        if encoding is not None and encoding != "base64":
            return f"Error: Unexpected encoding '{encoding}'"

        # GitHub's API returns base64 content with newlines; strip all whitespace
        normalized_b64 = "".join(content_b64.splitlines())

        try:
            decoded_bytes = base64.b64decode(normalized_b64, validate=True)
        except base64.binascii.Error:
            # Fallback: be permissive if the payload contains minor formatting quirks
            try:
                decoded_bytes = base64.b64decode(normalized_b64, validate=False)
            except Exception as e:
                return f"Error decoding base64: {e}"

        return decoded_bytes.decode("utf-8", errors="replace")
    except base64.binascii.Error as e:
        return f"Error decoding base64: {e}"


def main():
    if not gh_command_exists():
        print("Error: gh command not found")
        return

    if not is_authenticated():
        print("Error: User is not authenticated")
        return

    mcp.run()


if __name__ == "__main__":
    main()
