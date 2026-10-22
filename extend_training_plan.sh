#!/usr/bin/env bash
#
# Repeatable helper around the SageMaker training plan extension workflow:
#   https://docs.aws.amazon.com/sagemaker/latest/dg/training-plan-extension-using-api-cli-sdk.html
#   https://docs.aws.amazon.com/sagemaker/latest/dg/search-training-plan-offerings-api-cli-sdk.html
#
# Quick start (the two most-used commands):
#
#   Check the longest extension currently available, without buying anything:
#     ./extend_training_plan.sh search --plan-name b300 --max-days 182 --profile <aws-profile> --region <aws-region> 
#
#   Find the longest extension up to a cap and purchase it after confirming:
#     ./extend_training_plan.sh auto --plan-name b300 --max-days 182 --profile <aws-profile>  --region <aws-region>
#
# Subcommands map 1:1 to the SageMaker API actions:
#   list    -> ListTrainingPlans                    (what plans exist today)
#   search  -> SearchTrainingPlanOfferings          (what extensions are available for a plan)
#   extend  -> ExtendTrainingPlan                   (purchase an extension offering)
#   history -> DescribeTrainingPlanExtensionHistory (past/pending extensions for a plan)
#   auto    -> list (Active/Scheduled) -> search -> extend, with a confirmation prompt
#
# Constraints (per AWS docs -- https://docs.aws.amazon.com/sagemaker/latest/dg/training-plan-extension.html):
#   - The plan must be Active or Scheduled to extend; it must not already
#     have an extension in "Payment Pending" status.
#   - Extensions can be requested as early as 57 days before the plan
#     expires, and as late as 1 hour before expiry.
#   - Valid extension durations are 1-day increments up to 14 days, or
#     7-day increments up to 182 days (26 weeks) -- see valid_extension_days().
#
# Usage:
#
# Show all training plans (uses default profile "default" / region "us-west-2"):
#   ./extend_training_plan.sh list
#
# Show only plans with a given status (Pending | Active | Scheduled | Expired | Failed):
#   ./extend_training_plan.sh list --status Active
#
# Look up available extension offerings for a plan by name, for a 2-day extension:
#   ./extend_training_plan.sh search --plan-name b300 --duration-days 2
#
# Same, but by plan ARN instead of name:
#   ./extend_training_plan.sh search --plan-arn arn:aws:sagemaker:us-west-2:123456789012:training-plan/b300 --duration-days 2
#
# Purchase a specific extension offering returned by the "search" command above:
#   ./extend_training_plan.sh extend --offering-id tpeo-xxxxx
#
# View the full extension history (past, active, and pending) for a plan:
#   ./extend_training_plan.sh history --plan-name b300
#
# Search + show the best offering + prompt for confirmation before purchasing:
#   ./extend_training_plan.sh auto --plan-name b300 --duration-days 2
#
# Same, but skip the confirmation prompt (e.g. for cron/automation) -- the
# --yes below is commented out so a careless copy/paste doesn't trigger an
# unattended purchase; remove the "# " before --yes once you mean it:
#   ./extend_training_plan.sh auto --plan-name b300 --duration-days 2 # --yes
#
# Binary-search for the longest extension that currently has an offering, up
# to a 182-day cap, instead of specifying a fixed --duration-days:
#   ./extend_training_plan.sh search --plan-name b300 --max-days 182
#   ./extend_training_plan.sh auto   --plan-name b300 --max-days 182 # --yes
#
# Override the AWS CLI profile/region for a single invocation (works on any subcommand):
#   ./extend_training_plan.sh list --profile other-profile --region us-east-1
#
# Save this run's full output (progress + AWS CLI/JSON output) to a
# timestamped file under ./logs, in addition to the terminal (works on any subcommand):
#   ./extend_training_plan.sh auto --plan-name b300 --max-days 182 --save-logs
#
# Defaults / env overrides: PROFILE (default "default"), REGION (default us-west-2)

set -euo pipefail

PROFILE="${PROFILE:-default}"
REGION="${REGION:-us-west-2}"

aws_cli() {
    aws --profile "$PROFILE" --region "$REGION" "$@"
}

usage() {
    sed -n '2,70p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
}

# When --save-logs is passed, mirror all remaining stdout/stderr to a
# timestamped file under ./logs alongside the script, in addition to the
# terminal, so a run's full output (progress + AWS CLI/JSON output) is
# preserved for later review.
setup_log_file() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local log_dir="${script_dir}/logs"
    mkdir -p "$log_dir"
    local log_file="${log_dir}/$(date +%Y%m%d_%H%M%S).log"
    exec > >(tee -a "$log_file") 2>&1
    echo "Saving run output to: $log_file" >&2
}

check_deps() {
    local missing=()
    for bin in aws jq; do
        command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "Error: missing required dependencies: ${missing[*]}" >&2
        echo "Install them first, e.g. 'brew install ${missing[*]}' on macOS." >&2
        exit 1
    fi
}

resolve_plan_arn() {
    local plan_arn="$1" plan_name="$2"
    if [[ -n "$plan_arn" ]]; then
        echo "$plan_arn"
        return
    fi
    if [[ -z "$plan_name" ]]; then
        echo "Error: provide --plan-arn or --plan-name" >&2
        exit 1
    fi
    local arn
    arn=$(aws_cli sagemaker list-training-plans \
        --query "TrainingPlanSummaries[?TrainingPlanName=='${plan_name}'].TrainingPlanArn" \
        --output text)
    if [[ -z "$arn" || "$arn" == "None" ]]; then
        echo "Error: no training plan found with name '${plan_name}'" >&2
        exit 1
    fi
    echo "$arn"
}

# Valid extension lengths per AWS docs: 1-day increments up to 14 days,
# then 7-day increments up to 182 days (26 weeks). Returned ascending, capped
# at max_days (default 182).
valid_extension_days() {
    local max_days="${1:-182}"
    local d
    for ((d = 1; d <= 14 && d <= max_days; d++)); do
        echo "$d"
    done
    for ((d = 21; d <= 182 && d <= max_days; d += 7)); do
        echo "$d"
    done
}

offering_count_for_days() {
    local plan_arn="$1" days="$2"
    aws_cli sagemaker search-training-plan-offerings \
        --training-plan-arn "$plan_arn" \
        --duration-hours "$((days * 24))" \
        --query "length(TrainingPlanExtensionOfferings)" --output text
}

# Binary search over the valid-duration lattice for the longest extension
# that currently has an offering. Assumes feasibility is monotonic (if a
# longer duration has capacity, a shorter one does too) -- true in the
# common case, but not guaranteed if capacity is fragmented across windows.
find_max_extension_days() {
    local plan_arn="$1" max_days="$2"
    local -a days
    mapfile -t days < <(valid_extension_days "$max_days")

    echo "Binary searching ${#days[@]} valid durations (up to ${max_days}d) for the longest available extension..." >&2

    local lo=0 hi=$((${#days[@]} - 1)) best=-1 step=1
    while [[ $lo -le $hi ]]; do
        local mid=$(((lo + hi) / 2))
        local candidate="${days[$mid]}"
        echo -n "  [${step}] checking ${candidate}d... " >&2
        local count
        count=$(offering_count_for_days "$plan_arn" "$candidate")
        if [[ "$count" -gt 0 ]]; then
            echo "available" >&2
            best=$mid
            lo=$((mid + 1))
        else
            echo "not available" >&2
            hi=$((mid - 1))
        fi
        step=$((step + 1))
    done

    if [[ $best -eq -1 ]]; then
        echo 0
    else
        echo "${days[$best]}"
    fi
}

cmd_list() {
    local status_filter=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --status) status_filter="$2"; shift 2 ;;
            *) echo "Unknown arg: $1" >&2; usage ;;
        esac
    done

    local filter_args=()
    [[ -n "$status_filter" ]] && filter_args=(--filters "Name=Status,Value=${status_filter}")

    aws_cli sagemaker list-training-plans \
        --sort-by StartTime --sort-order Descending \
        "${filter_args[@]}" \
        --query "TrainingPlanSummaries[].{Name:TrainingPlanName,Status:Status,Start:StartTime,End:EndTime,ARN:TrainingPlanArn}" \
        --output table
}

cmd_search() {
    local plan_arn="" plan_name="" duration_days="" max_days=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --plan-arn) plan_arn="$2"; shift 2 ;;
            --plan-name) plan_name="$2"; shift 2 ;;
            --duration-days) duration_days="$2"; shift 2 ;;
            --max-days) max_days="$2"; shift 2 ;;
            *) echo "Unknown arg: $1" >&2; usage ;;
        esac
    done

    if [[ -n "$duration_days" && -n "$max_days" ]]; then
        echo "Error: specify either --duration-days or --max-days, not both" >&2
        exit 1
    fi

    plan_arn=$(resolve_plan_arn "$plan_arn" "$plan_name")

    if [[ -n "$max_days" ]]; then
        duration_days=$(find_max_extension_days "$plan_arn" "$max_days")
        if [[ "$duration_days" -eq 0 ]]; then
            echo "No extension offering found for any duration up to ${max_days} days." >&2
            exit 1
        fi
        echo "Largest feasible extension within ${max_days}-day cap: ${duration_days} day(s)" >&2
    fi

    local duration_args=()
    [[ -n "$duration_days" ]] && duration_args=(--duration-hours "$((duration_days * 24))")

    aws_cli sagemaker search-training-plan-offerings \
        --training-plan-arn "$plan_arn" \
        "${duration_args[@]}"
}

cmd_extend() {
    local offering_id=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --offering-id) offering_id="$2"; shift 2 ;;
            *) echo "Unknown arg: $1" >&2; usage ;;
        esac
    done

    if [[ -z "$offering_id" ]]; then
        echo "Error: --offering-id is required (starts with tpeo-)" >&2
        exit 1
    fi

    aws_cli sagemaker extend-training-plan \
        --training-plan-extension-offering-id "$offering_id"
}

cmd_history() {
    local plan_arn="" plan_name=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --plan-arn) plan_arn="$2"; shift 2 ;;
            --plan-name) plan_name="$2"; shift 2 ;;
            *) echo "Unknown arg: $1" >&2; usage ;;
        esac
    done

    plan_arn=$(resolve_plan_arn "$plan_arn" "$plan_name")

    aws_cli sagemaker describe-training-plan-extension-history \
        --training-plan-arn "$plan_arn" \
        --query "TrainingPlanExtensions[].{OfferingId:TrainingPlanExtensionOfferingId,ExtendedAt:ExtendedAt,Start:StartDate,End:EndDate,Status:Status,Payment:PaymentStatus,Hours:DurationHours,Fee:UpfrontFee,Currency:CurrencyCode}" \
        --output table
}

cmd_auto() {
    local plan_arn="" plan_name="" duration_days="" max_days="" auto_yes="false"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --plan-arn) plan_arn="$2"; shift 2 ;;
            --plan-name) plan_name="$2"; shift 2 ;;
            --duration-days) duration_days="$2"; shift 2 ;;
            --max-days) max_days="$2"; shift 2 ;;
            --yes) auto_yes="true"; shift ;;
            *) echo "Unknown arg: $1" >&2; usage ;;
        esac
    done

    if [[ -n "$duration_days" && -n "$max_days" ]]; then
        echo "Error: specify either --duration-days or --max-days, not both" >&2
        exit 1
    fi
    if [[ -z "$duration_days" && -z "$max_days" ]]; then
        echo "Error: --duration-days or --max-days is required" >&2
        exit 1
    fi

    plan_arn=$(resolve_plan_arn "$plan_arn" "$plan_name")

    if [[ -n "$max_days" ]]; then
        echo "Searching for the largest feasible extension (up to ${max_days}d) for: $plan_arn" >&2
        duration_days=$(find_max_extension_days "$plan_arn" "$max_days")
        if [[ "$duration_days" -eq 0 ]]; then
            echo "No extension offering found for any duration up to ${max_days} days." >&2
            exit 1
        fi
        echo "Largest feasible extension: ${duration_days} day(s)" >&2
    fi

    echo "Searching extension offerings for: $plan_arn (duration ${duration_days}d)" >&2

    local search_json
    search_json=$(aws_cli sagemaker search-training-plan-offerings \
        --training-plan-arn "$plan_arn" \
        --duration-hours "$((duration_days * 24))")

    local offering_count
    offering_count=$(echo "$search_json" | jq '.TrainingPlanExtensionOfferings | length')

    if [[ "$offering_count" -eq 0 ]]; then
        echo "No extension offerings available for this plan/duration. Try a different --duration-days." >&2
        exit 1
    fi

    echo "$search_json" | jq '.TrainingPlanExtensionOfferings'

    local offering_id
    offering_id=$(echo "$search_json" | jq -r '.TrainingPlanExtensionOfferings[0].TrainingPlanExtensionOfferingId')
    local upfront_fee
    upfront_fee=$(echo "$search_json" | jq -r '.TrainingPlanExtensionOfferings[0].UpfrontFee')
    local currency
    currency=$(echo "$search_json" | jq -r '.TrainingPlanExtensionOfferings[0].CurrencyCode')

    echo "" >&2
    echo "Best match: $offering_id (upfront fee: ${upfront_fee} ${currency})" >&2

    if [[ "$auto_yes" != "true" ]]; then
        read -r -p "Purchase this extension offering? [y/N] " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            echo "Aborted. No purchase made." >&2
            exit 0
        fi
    fi

    aws_cli sagemaker extend-training-plan \
        --training-plan-extension-offering-id "$offering_id"
}

main() {
    check_deps

    local sub="${1:-}"
    [[ $# -gt 0 ]] && shift

    # Pull --profile/--region/--save-logs out of the remaining args (any
    # position) so each subcommand's own parser doesn't need to know about them.
    local rest=() save_logs="false"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --profile) PROFILE="$2"; shift 2 ;;
            --region) REGION="$2"; shift 2 ;;
            --save-logs) save_logs="true"; shift ;;
            *) rest+=("$1"); shift ;;
        esac
    done

    [[ "$save_logs" == "true" ]] && setup_log_file

    case "$sub" in
        list) cmd_list "${rest[@]}" ;;
        search) cmd_search "${rest[@]}" ;;
        extend) cmd_extend "${rest[@]}" ;;
        history) cmd_history "${rest[@]}" ;;
        auto) cmd_auto "${rest[@]}" ;;
        *) usage ;;
    esac
}

main "$@"
