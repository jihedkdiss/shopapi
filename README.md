# shopapi

A tiny Node.js API with security mistakes planted on purpose, for a DevSecOps workshop.

Every push runs a GitHub Actions pipeline (`.github/workflows/ci.yml`) with five security gates.
Right now, every gate is red. Your job: make them green, one at a time, without disabling any of them.

| Gate | Tool | What it catches here |
|---|---|---|
| secrets | Gitleaks | an AWS key that is still in git history |
| sast | Semgrep (and Snyk Code once `SNYK_TOKEN` is set) | an SQL injection in `app.js` |
| sca | Trivy fs | old npm packages with known CVEs |
| iac | Trivy config | a public S3 bucket and SSH open to the world in `infra/main.tf` |
| image | Trivy image | an end-of-life base image running as root |

When all five pass on `main`, the pipeline deploys to AWS with OIDC (no stored keys):
image to Amazon ECR, then an SSM command tells an EC2 instance to pull it. ZAP then scans the live app.

> Scan only what you own. All keys in this repo are fake.

## Run the scanners locally

```bash
gitleaks git -v .                       # every commit, not just today's files
semgrep scan --config p/owasp-top-ten --config p/expressjs app.js
trivy fs --scanners vuln --severity HIGH,CRITICAL .
trivy config .
```

## Instructor notes

AWS setup and teardown live in `deploy/` (`aws-setup.sh`, `aws-teardown.sh`).
A fully fixed version is on the `solution` branch.
