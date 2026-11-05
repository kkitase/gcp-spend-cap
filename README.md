# gcp-spend-cap

Japanese: [README-ja.md](README-ja.md)

`gcp-spend-cap.sh` manages Cloud Billing **spend cap budgets**. A spend cap budget pauses new usage of one service in one project when its monthly cost reaches the amount you set.

| Key | Service |
| --- | --- |
| `gemini` | Gemini API |
| `vertex` | Gemini platform (formerly Vertex AI) |
| `run` | Cloud Run |
| `functions` | Cloud Run functions |

## Requirements

- bash 3.2 or later, `curl` and `jq`. All three are preinstalled on macOS 15 or later and in Cloud Shell. On Linux, install `jq` if needed (`sudo apt install jq`).
- gcloud CLI, signed in. The tool uses the **active gcloud configuration** (`gcloud auth login`), and falls back to Application Default Credentials when the user token needs reauthentication. To use another configuration, prefix the command, for example `CLOUDSDK_CONFIG=~/.config/gcloud-other ./gcp-spend-cap.sh ...`.
- `billingbudgets.googleapis.com` and `cloudbilling.googleapis.com` enabled on the project. Add `--enable-api` on the first run.

## Usage

On the **first run** against a project (even if you only run `status`), pass **`--enable-api`** to enable `billingbudgets.googleapis.com` and `cloudbilling.googleapis.com`. Once enabled, `--enable-api` is no longer needed.

```bash
# Check current caps on a project for the first time (pass --enable-api on the first run)
./gcp-spend-cap.sh status -p my-project --enable-api

# Cap all four services at 10,000 per month (add --enable-api if not enabled yet)
./gcp-spend-cap.sh set -p my-project -a 10000

# Only Gemini API and Gemini platform; preview first
./gcp-spend-cap.sh set -p my-project -a 5000 -s gemini,vertex --dry-run

# Show caps and their state (once APIs are enabled)
./gcp-spend-cap.sh status -p my-project

# Resume usage that was paused because a cap was reached
./gcp-spend-cap.sh lift -p my-project

# Delete the caps without a prompt
./gcp-spend-cap.sh delete -p my-project --yes
```

Options for every command: `-p` project (default: current gcloud project), `-s` services (`all` or a comma-separated list), `-y` skip confirmation, `--dry-run`, `--enable-api`. `set` also takes `-a` amount and `--force`. Run `./gcp-spend-cap.sh --help` for details.

## Checking in the Google Cloud console

You can also view, edit, lift, or delete spend cap budgets in the Google Cloud console on the **Budgets & alerts** page:

- **With Billing Account permissions**: Open [Budgets & alerts](https://console.cloud.google.com/billing/budgets) and select your Cloud Billing account.
- **With project-level permissions only**: Select the target project in the Google Cloud console project picker first, open **Billing** from the navigation menu (click **Go to linked billing account** if prompted), and select **Budgets & alerts** under **Cost management**.

Check the **Spend cap status** column in the budget list:

- **Configured**: Active and monitoring monthly spend, not yet reached.
- **Enforced**: The target amount was reached and new usage of the service is paused. To resume usage manually, click the budget name, select **Lift spend cap**, and confirm.
- **Lifted**: Manually lifted for the rest of the current month.
- **Not applicable**: Regular alerts-only budget without a spend cap.

## Behavior

- **set** shows a plan and asks for confirmation. Existing caps are updated in place. A cap that was reached (state `ENFORCED`) is skipped unless you pass `--force`, because lifting it resumes paused usage.
- **lift** only touches reached caps. A lifted cap stays off for the rest of the month unless you raise the amount with `set`. Services can take up to one hour to resume.
- **delete** lifts reached caps first (the API requires it), then deletes them.
- If one service fails, the others still run. The exit code is 1 when anything failed or was skipped.
- The access token is passed to curl through a private temporary file, so it does not appear in the process list.

## Working with free credits and coupons

Spend caps always track gross list-price usage (`EXCLUDE_ALL_CREDITS` is required by the API), so usage covered by free trial credits or promotional coupons still counts toward the cap. To pause usage only when you start paying out of pocket, add your remaining credit balance to the cap amount (`remaining credits + acceptable out-of-pocket spend`):

- **Example**: With JPY 30,000 in coupons and a JPY 1,000 out-of-pocket limit, pass `-a 31000` (or set slightly below the coupon balance, such as `-a 28000`, to stay at zero out-of-pocket cost despite reporting delay).
- **Monthly adjustment**: Monthly spend resets to zero on the first day of each month, while coupon balances carry over and decrease across months. Check your remaining balance under **Billing** > **Credits** in the Google Cloud console at the start of each month and update the amount with `./gcp-spend-cap.sh set`. Every command prints a link to that page on the `Credits:` line (no public API returns the balance itself).
- **Multiple services**: Because each cap applies to a single service, split your remaining coupon balance across the services you actively use.

## Limits of spend caps

- Caps use estimated list-price costs and are not instant (about 10 minutes of delay, and running requests finish). Small overages are still billed, so set the amount a little below your real limit.
- Credits and discounts are ignored (`EXCLUDE_ALL_CREDITS` is required); see **Working with free credits and coupons** above.
- Fixed costs are not paused, for example Cloud Run minimum instances or storage.
- Your cap settings stay in place across months (you do not need to recreate them). On the first day of each month, the tracked monthly spend resets to zero, and any `ENFORCED` or `AWAITING_NEXT_PERIOD` (lifted) cap automatically returns to `CONFIGURED` (resuming paused services). Spend cap budgets only support monthly periods; non-resetting lifetime or custom-period caps are not supported by the API.
- The tool does not use Context-Aware Access client certificates, so CAA-protected accounts may be rejected.

## Permissions

On the project: `resourcemanager.projects.get`, `billing.resourcebudgets.read`, `billing.resourcebudgets.write`, `billing.resourcebudgets.configureSpendCap`, and `serviceusage.services.use` (plus `serviceusage.services.enable` when passing `--enable-api`). Billing Account Administrator also works for the budget permissions, though `resourcemanager.projects.get` and `serviceusage.services.use` on the project are still required. Showing the currency needs `billing.accounts.get`.

## References

- [Manage spend cap budgets](https://cloud.google.com/billing/docs/how-to/budgets-spend-caps)
- [Using the Cloud Billing Budget API for spend cap budgets](https://cloud.google.com/billing/docs/how-to/budget-api-spend-cap)
