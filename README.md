# extend-training-plan

A repeatable bash CLI around the [SageMaker Training Plan](https://docs.aws.amazon.com/sagemaker/latest/dg/reserve-capacity-with-training-plans.html) extension workflow: list plans, search for available extension offerings, and purchase an extension — including a binary search to automatically find the longest extension currently available.

## Why

Training plan extensions are only available in specific windows and durations (see [Constraints](#constraints) below). Rather than guessing a duration and re-running `aws sagemaker search-training-plan-offerings` by hand, this script automates the search/extend flow and can binary-search for the largest feasible extension up to a cap you choose.

## Requirements

- [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html), configured with credentials that have `sagemaker:ListTrainingPlans`, `sagemaker:SearchTrainingPlanOfferings`, and `sagemaker:ExtendTrainingPlan` permissions
- [`jq`](https://jqlang.github.io/jq/)

On macOS: `brew install awscli jq`

The script checks for both on startup and exits with an install hint if either is missing.

**Windows:** this is a bash script and will not run directly in PowerShell or `cmd.exe`. Use [Git Bash](https://git-scm.com/downloads), [WSL](https://learn.microsoft.com/en-us/windows/wsl/install), or Cygwin, and install `awscli`/`jq` inside that environment.

## Quick start

```bash
# Check the longest extension currently available, without buying anything
./extend_training_plan.sh search --plan-name <your-plan-name> --max-days 90 --profile <your-profile>

# Find the longest extension up to a cap and purchase it after confirming
./extend_training_plan.sh auto --plan-name <your-plan-name> --max-days 30 --profile <your-profile>
```

## Subcommands

Subcommands map 1:1 to the SageMaker API actions:

| Subcommand | API action | Purpose |
|---|---|---|
| `list` | `ListTrainingPlans` | What plans exist today |
| `search` | `SearchTrainingPlanOfferings` | What extensions are available for a plan |
| `extend` | `ExtendTrainingPlan` | Purchase an extension offering |
| `history` | `DescribeTrainingPlanExtensionHistory` | Past, active, and pending extensions for a plan |
| `auto` | list → search → extend | Full flow in one command, with a confirmation prompt |

## Usage

Show all training plans (uses default profile `default` / region `us-west-2`):
```bash
./extend_training_plan.sh list
```

Show only plans with a given status (`Pending` | `Active` | `Scheduled` | `Expired` | `Failed`):
```bash
./extend_training_plan.sh list --status Active
```

Look up available extension offerings for a plan by name, for a fixed duration:
```bash
./extend_training_plan.sh search --plan-name b300 --duration-days 2
```

Same, but by plan ARN instead of name:
```bash
./extend_training_plan.sh search --plan-arn arn:aws:sagemaker:us-west-2:123456789012:training-plan/b300 --duration-days 2
```

Purchase a specific extension offering returned by `search`:
```bash
./extend_training_plan.sh extend --offering-id tpeo-xxxxx
```

View the full extension history (past, active, and pending) for a plan:
```bash
./extend_training_plan.sh history --plan-name b300
```

Search, show the best offering, and prompt for confirmation before purchasing:
```bash
./extend_training_plan.sh auto --plan-name b300 --duration-days 2
```

Skip the confirmation prompt (e.g. for cron/automation). The `--yes` in the examples below is commented out so a careless copy/paste can't trigger an unattended purchase — remove the `# ` before `--yes` once you mean it:
```bash
./extend_training_plan.sh auto --plan-name b300 --duration-days 2 # --yes
```

### Finding the longest available extension (`--max-days`)

Instead of guessing a `--duration-days`, binary-search for the longest extension that currently has an offering, up to a cap:
```bash
./extend_training_plan.sh search --plan-name b300 --max-days 182
./extend_training_plan.sh auto   --plan-name b300 --max-days 182 # --yes
```
The search prints live progress (each duration it's probing and whether it's available) so it's clear the script isn't stuck.

### Other flags

Override the AWS CLI profile/region for a single invocation (works on any subcommand):
```bash
./extend_training_plan.sh list --profile other-profile --region us-east-1
```

Save this run's full output (progress + AWS CLI/JSON output) to a timestamped file under `./logs`, in addition to the terminal (works on any subcommand):
```bash
./extend_training_plan.sh auto --plan-name b300 --max-days 182 --save-logs
```

## Defaults / env overrides

| Variable | Default | Flag override |
|---|---|---|
| `PROFILE` | `default` | `--profile` |
| `REGION` | `us-west-2` | `--region` |

## Constraints

Per the [AWS training plan extension docs](https://docs.aws.amazon.com/sagemaker/latest/dg/training-plan-extension.html):

- The plan must be `Active` or `Scheduled` to extend; it must not already have an extension in `Payment Pending` status.
- Extensions can be requested as early as 57 days before the plan expires, and as late as 1 hour before expiry.
- Valid extension durations are 1-day increments up to 14 days, or 7-day increments up to 182 days (26 weeks) — see `valid_extension_days()` in the script.
- Purchases/extensions are final and cannot be cancelled.

## How the binary search works

`find_max_extension_days()` doesn't bisect the raw day range (1–182); it bisects the *index* of the discrete list of valid durations generated by `valid_extension_days()` — 14 daily values (1–14) followed by 24 weekly values (21, 28, ..., 182), 38 values total. Because that list is front-loaded with daily increments, the midpoint by index (e.g. 49 days) is much lower than the midpoint by raw value (91 days) would suggest. Each probe calls `SearchTrainingPlanOfferings` for that duration; availability is assumed monotonic (if a longer duration has capacity, so does a shorter one), so the search narrows to the longest available duration in about `ceil(log2(38))` ≈ 6 calls instead of checking all 38.

## Notes

- Each `search` call returns freshly generated `TrainingPlanExtensionOfferingId` values — don't reuse an ID from an old `search` run with `extend`. Use `auto`, which searches and extends in the same run, or re-run `search` immediately before `extend`.
- This script does not implement any scheduling (cron/launchd) — it's a plain CLI you can wire into whatever scheduler you prefer.
