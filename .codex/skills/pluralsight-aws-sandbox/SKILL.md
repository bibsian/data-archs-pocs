---
name: pluralsight-aws-sandbox
description: Start a Pluralsight AWS cloud sandbox in Google Chrome and prepare its temporary credentials for the local AWS CLI. Use for an interactive sandbox setup; do not use to deploy, change, or destroy AWS resources.
---

# Pluralsight AWS Sandbox

Prepare a Pluralsight AWS sandbox through the repository README's credential-configuration step, then hand control back before the standalone **Verify** step.

## Required interaction

- Use the `@Computer` integration and the **Google Chrome application** for all Pluralsight and AWS Console navigation. Do not substitute an in-app browser or a web connector.
- Keep Chrome visible. At handoff, leave the tab with the active AWS Console session open and usable.
- Treat account passwords, sandbox passwords, access-key IDs, and secret access keys as sensitive. Never ask the user to paste them into chat, repeat them, store them in the skill, add them to files, commit them, or expose them in command output. When the user requests complete sandbox setup, use the values displayed in the Pluralsight sandbox directly for AWS sign-in and CLI configuration; otherwise leave credential entry to the user.
- If Pluralsight sign-in is not already complete, navigate to <https://app.pluralsight.com/id>. Use a saved browser credential only when Chrome offers it; otherwise stop UI automation and ask the user to sign in directly in Chrome. Resume only after the signed-in page is visible.

## Workflow

1. Read the workspace's `README.md` and `scripts/configure-sandbox.sh` before acting. Follow the current repository instructions if they differ from this skill. Confirm that the workspace contains the configuration script; if it does not, report the missing prerequisite and stop.
2. In Chrome, open <https://app.pluralsight.com/hands-on/playground/cloud-sandboxes>. Start or open an **AWS Sandbox**. If the user must select an entitlement, region, sandbox, or any billing-relevant option that the README does not specify, ask them to choose. Wait until its AWS Console credentials and launch control are available.
3. Open the AWS Console from that sandbox in Chrome. Complete the console sign-in in a separate/private Chrome context when Pluralsight requires it, while keeping an accessible AWS Console tab open at the end. For a complete setup request, enter the displayed sandbox username and password directly; do not reveal them in chat or logs.
4. In the AWS Console, go to the signed-in user's **Security credentials** page. First check for an active key that matches the access key displayed by Pluralsight; use that pair for CLI setup. Create one key only if no usable sandbox-provided key exists and the user requested complete setup. Do not create additional keys, disable keys, or make unrelated IAM changes.
5. Use an existing visible user terminal if possible; otherwise open a terminal session the user can take over. Change it to the repository root and make sure `aws` resolves in that terminal. If it is missing, explain that the README requires installing it and obtain approval before running the repository's installation command.
6. Run `bash scripts/configure-sandbox.sh`. For a complete setup request, supply the displayed access key ID, secret access key, and default region without exposing them in terminal output; otherwise stop for the user to enter them. If the workspace sandbox prevents writing `~/.aws/credentials`, request the minimum permission needed and rerun that same script. The script's own connection check is part of configuration; do not separately run the README's standalone **Verify** command.
7. Once credentials are configured successfully, run `bash scripts/tf-guard.sh` from the repository root. This scans every project under `terraform/` for local state left over from a previous (now-expired) sandbox account and automatically archives any stale state it finds, so the next `terraform plan`/`apply` starts clean against the current sandbox account. It only inspects and archives local state files — it does not deploy, modify, or destroy any cloud resources — so it is safe to run as part of setup. If the workspace does not contain this script, skip it and note that it is missing.
8. Leave the terminal visible, at its normal prompt in the repository root, with the `pluralsight` profile configured. Do not deploy infrastructure, run Terraform, create cloud resources, or execute `aws sts get-caller-identity --profile pluralsight` as a separate command.

## Handoff

Report only non-sensitive status: whether Chrome is signed into the sandbox's AWS Console, whether the `pluralsight` CLI profile was configured, whether `scripts/tf-guard.sh` ran and, if so, which project(s) (if any) had stale state archived, and that the user can now run the README's **Verify** command in the open terminal. If access-key creation, sign-in, the terminal prompt, or sandbox provisioning cannot proceed without user input, clearly say what is currently waiting for them.
