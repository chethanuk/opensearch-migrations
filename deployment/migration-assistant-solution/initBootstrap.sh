#!/bin/bash

set -euo pipefail

script_dir=$(dirname "${BASH_SOURCE[0]}")
SCRIPT_DIR=$(cd "$script_dir" && pwd)
unset script_dir
readonly SCRIPT_DIR
if [[ "$(basename "$SCRIPT_DIR")" == "migration-assistant-solution" ]] && [[ "$(basename "$(dirname "$SCRIPT_DIR")")" == "deployment" ]]; then
  readonly REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
else
  readonly REPO_ROOT="$SCRIPT_DIR"
fi
readonly MIGRATIONS_REPO_URL="${OPENSEARCH_MIGRATIONS_GIT_URL:-https://github.com/opensearch-project/opensearch-migrations.git}"
readonly MIGRATIONS_BOOTSTRAP_DIR="deployment/cdk/opensearch-service-migration"
readonly RELEASE_LOOKUP_TIMEOUT_SECONDS=20
readonly AWS_CDK_VERSION="2.x"

usage() {
  echo "Usage: $0 [--tag <tag_name>] [--branch <branch_name>]"
  exit 1
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

require_option_value() {
  local option_name="$1"
  local option_value="${2:-}"
  if [[ -z "$option_value" || "$option_value" == --* ]]; then
    fail "Option $option_name requires a value."
  fi
}

initialize_git_repository() {
  git init
}

setup_origin_remote() {
  if git remote get-url origin >/dev/null 2>&1; then
    git remote set-url origin "$MIGRATIONS_REPO_URL"
  else
    git remote add origin "$MIGRATIONS_REPO_URL"
  fi
}

fetch_origin_refs() {
  git fetch --force --tags origin "+refs/heads/*:refs/remotes/origin/*"
}

resolve_tag_ref() {
  local selected_tag="$1"
  local tag_ref="refs/tags/$selected_tag"

  if ! git rev-parse --verify --quiet "${tag_ref}^{commit}" >/dev/null; then
    fail "Git tag '$selected_tag' was not found on origin. Check the tag name and try again."
  fi

  printf '%s\n' "$tag_ref"
}

resolve_branch_ref() {
  local selected_branch="$1"
  local branch_ref="refs/remotes/origin/$selected_branch"

  if ! git rev-parse --verify --quiet "${branch_ref}^{commit}" >/dev/null; then
    fail "Git branch '$selected_branch' was not found on origin. Check the branch name and try again."
  fi

  printf '%s\n' "$branch_ref"
}

get_latest_release_tag() {
  local latest_release_tag
  latest_release_tag=$(curl --connect-timeout 5 --max-time "$RELEASE_LOOKUP_TIMEOUT_SECONDS" -fsSL https://api.github.com/repos/opensearch-project/opensearch-migrations/releases/latest | jq -er '.tag_name') || \
    fail "Unable to determine the latest release tag from GitHub."
  printf '%s\n' "$latest_release_tag"
}

escape_for_sed_replacement() {
  local raw_value="$1"
  raw_value=${raw_value//\\/\\\\}
  raw_value=${raw_value//&/\\&}
  raw_value=${raw_value//|/\\|}
  printf '%s\n' "$raw_value"
}

validate_required_bootstrap_paths_in_ref() {
  local git_ref="$1"
  local ref_label="$2"
  local required_paths=(
    "$MIGRATIONS_BOOTSTRAP_DIR"
    "$MIGRATIONS_BOOTSTRAP_DIR/buildDockerImages.sh"
    "$MIGRATIONS_BOOTSTRAP_DIR/cdk.context.json"
  )
  local required_path

  for required_path in "${required_paths[@]}"; do
    if ! git cat-file -e "${git_ref}:${required_path}" 2>/dev/null; then
      fail "Selected $ref_label is missing required bootstrap path '$required_path'."
    fi
  done
}

checkout_tag_ref() {
  local tag_ref="$1"
  git checkout --force --detach "$tag_ref"
}

checkout_branch_ref() {
  local selected_branch="$1"
  local branch_ref="$2"
  git checkout --force -B "$selected_branch" "$branch_ref"
}

get_bootstrap_dir() {
  printf '%s\n' "$REPO_ROOT/$MIGRATIONS_BOOTSTRAP_DIR"
}

validate_bootstrap_dir_exists() {
  local bootstrap_dir
  bootstrap_dir=$(get_bootstrap_dir)

  if [[ ! -d "$bootstrap_dir" ]]; then
    fail "Required bootstrap directory '$bootstrap_dir' was not found after checkout."
  fi
}

parse_args() {
  tag=""
  branch=""

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --tag)
        require_option_value "$1" "${2:-}"
        if [[ -n "$branch" ]]; then
          fail "You cannot specify both --tag and --branch."
        fi
        tag="$2"
        shift 2
        ;;
      --branch)
        require_option_value "$1" "${2:-}"
        if [[ -n "$tag" ]]; then
          fail "You cannot specify both --tag and --branch."
        fi
        branch="$2"
        shift 2
        ;;
      -h|--help)
        usage
        ;;
      *)
        fail "Unknown parameter passed: $1"
        ;;
    esac
  done
}

main() {
  local checkout_ref=""
  local bootstrap_dir=""
  local checkout_label=""
  local latest_release_tag=""

  parse_args "$@"

  yum update && yum install -y git java-17-amazon-corretto-devel docker nodejs22 nodejs22-npm https://s3.amazonaws.com/session-manager-downloads/plugin/latest/linux_64bit/session-manager-plugin.rpm
  systemctl start docker

  initialize_git_repository
  setup_origin_remote
  fetch_origin_refs

  if [[ -n "$branch" ]]; then
    checkout_ref=$(resolve_branch_ref "$branch")
    checkout_label="branch '$branch'"
    validate_required_bootstrap_paths_in_ref "$checkout_ref" "$checkout_label"
    checkout_branch_ref "$branch" "$checkout_ref"
  else
    if [[ -n "$tag" ]]; then
      latest_release_tag="$tag"
      checkout_label="tag '$tag'"
    else
      latest_release_tag=$(get_latest_release_tag)
      checkout_label="latest release tag '$latest_release_tag'"
    fi

    checkout_ref=$(resolve_tag_ref "$latest_release_tag")
    validate_required_bootstrap_paths_in_ref "$checkout_ref" "$checkout_label"
    checkout_tag_ref "$checkout_ref"
  fi

  validate_bootstrap_dir_exists
  bootstrap_dir=$(get_bootstrap_dir)
  cd "$bootstrap_dir"

  if [[ -n "${VPC_ID:-}" ]]; then
    local escaped_vpc_id
    escaped_vpc_id=$(escape_for_sed_replacement "$VPC_ID")
    sed -i "s|<VPC_ID>|$escaped_vpc_id|g" "$bootstrap_dir/cdk.context.json"
  fi
  if [[ -n "${STAGE:-}" ]]; then
    local escaped_stage
    escaped_stage=$(escape_for_sed_replacement "$STAGE")
    sed -i "s|<STAGE>|$escaped_stage|g" "$bootstrap_dir/cdk.context.json"
  fi

  npm install -g "aws-cdk@${AWS_CDK_VERSION}" 2>&1
  npm install 2>&1
  ./buildDockerImages.sh
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
