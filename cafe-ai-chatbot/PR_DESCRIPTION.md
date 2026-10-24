<!--
  Commit message and PR description for adding this project to your
  cloud-projects GitHub repo. Copy the sections below as-is.
-->

## Commit message

```
feat: add Bedrock AI chatbot extension to Cafe RDS migration lab

- Add CafeChatbotFunction (Lambda) that answers menu questions via
  Amazon Bedrock (Claude 3.5 Haiku, Converse API), grounded in the
  live menu_items table in the lab's RDS MariaDB instance
- Expose it through an API Gateway HTTP API (/chat) called from a
  chat widget embedded in the existing cafe web app
- Reach Bedrock and Secrets Manager over VPC interface endpoints
  (no NAT Gateway, no public Lambda)
- Add CafeChatbotSG with scoped ingress into CafeDatabaseSG
- Document build/test/teardown steps and add an updated
  architecture diagram (docs/architecture-with-ai.svg)
```

## Pull request description

### Summary

Extends the "Migrate a Café Web Application to Amazon RDS" lab project with a serverless, generative-AI chatbot. The assistant answers customer questions about the café menu directly on the website, grounded in the same RDS MariaDB data the base lab migrates — not a bolt-on demo, it queries the project's own database.

### What's new

- **`lambda/chatbot_handler.py`** — Lambda handler: reads RDS credentials from Secrets Manager, queries `menu_items`, builds a grounded system prompt, calls Bedrock's Converse API, returns the reply.
- **`web/chatbot-widget.html`** — drop-in chat widget (vanilla HTML/JS) for the café app's existing page template.
- **`iam/cafe-chatbot-lambda-policy.json`** + **`lambda/lambda-trust-policy.json`** — least-privilege IAM for the Lambda execution role (Bedrock invoke, Secrets Manager read, VPC ENI management, CloudWatch Logs only).
- **`cli-commands.sh`** — full build script (Secrets Manager secret, IAM role, security group, VPC interface endpoints, Lambda, API Gateway) using the same AWS CLI approach as the base lab's Task 2.
- **`docs/architecture-with-ai.svg`** / **`.png`** — updated architecture diagram; new resources are outlined in gold against the base lab's existing diagram style.
- **`README.md`** — full build, test, monitoring, cost, and teardown instructions.

### Architecture

See `docs/architecture-with-ai.svg`. In short: browser → API Gateway → Lambda (private subnet) → RDS MariaDB (menu data) + Bedrock Runtime via VPC endpoint (AI reply) + Secrets Manager via VPC endpoint (DB credentials).

### Why

Shows four skills beyond the base migration lab: generative AI integration (Bedrock), serverless architecture (Lambda + API Gateway), retrieval-grounded prompting (answers come from real data, not hallucination), and private networking (VPC interface endpoints instead of a NAT Gateway or public Lambda).

### Test plan

- [ ] Deploy following `README.md` steps 1–7
- [ ] Ask the widget a menu/price question — confirm the reply matches the actual `menu_items` rows
- [ ] Ask an off-menu question — confirm the assistant declines instead of inventing an answer
- [ ] Confirm `CloudWatch Logs /aws/lambda/CafeChatbotFunction` shows successful Secrets Manager + Bedrock calls
- [ ] Confirm `CafeChatbotLambdaErrors` alarm creates cleanly
- [ ] Tear down with the commands in `README.md` and confirm no orphaned resources remain (VPC endpoints are the easy one to forget — they bill hourly)

### Cost / cleanup note

VPC interface endpoints run ~$0.01/hr each plus data processing; everything else is pay-per-use or free-tier eligible. Tear down after recording the demo if not needed long-term.
