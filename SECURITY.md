# Security Policy

TailnetKit is pre-1.0 and under active extraction. Treat it as not yet
production-ready.

Report vulnerabilities privately through GitHub's "Report a vulnerability"
button on the Security tab. Please don't open public issues for security
reports.

Tailnet node state, auth keys, and login URLs are sensitive. Node state is kept
in per-profile directories with file protection, and payloads are never logged;
see DESIGN.md for the handling rules.
