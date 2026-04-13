#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)
SCRIPT_UNDER_TEST="$REPO_ROOT/deployment/migration-assistant-solution/initBootstrap.sh"

TEST_TMP_DIR=$(mktemp -d)
cleanup() {
  rm -rf "$TEST_TMP_DIR"
}
trap cleanup EXIT

make_stub_commands() {
  local stub_dir="$1"
  mkdir -p "$stub_dir"

  cat > "$stub_dir/yum" <<'EOF'
#!/bin/bash
exit 0
EOF

  cat > "$stub_dir/systemctl" <<'EOF'
#!/bin/bash
exit 0
EOF

  chmod +x "$stub_dir/yum" "$stub_dir/systemctl"
}

assert_contains() {
  local expected="$1"
  local file_path="$2"
  if ! grep -Fq "$expected" "$file_path"; then
    echo "Expected output to contain: $expected"
    echo "Actual output:"
    cat "$file_path"
    exit 1
  fi
}

assert_equals() {
  local expected="$1"
  local actual="$2"
  if [[ "$expected" != "$actual" ]]; then
    echo "Expected: $expected"
    echo "Actual:   $actual"
    exit 1
  fi
}

create_test_remote() {
  local remote_dir="$1"
  local seed_dir="$2"

  git init --bare "$remote_dir" >/dev/null 2>&1
  git init "$seed_dir" >/dev/null 2>&1

  (
    cd "$seed_dir"
    git config user.name "bootstrap-test"
    git config user.email "bootstrap-test@example.com"

    echo "placeholder" > README.md
    git add README.md
    git commit -m "initial" >/dev/null 2>&1
    git tag missing-path

    mkdir -p deployment/cdk/opensearch-service-migration
    cat > deployment/cdk/opensearch-service-migration/cdk.context.json <<'EOF'
{}
EOF
    cat > deployment/cdk/opensearch-service-migration/buildDockerImages.sh <<'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x deployment/cdk/opensearch-service-migration/buildDockerImages.sh

    git add deployment/cdk/opensearch-service-migration
    git commit -m "add bootstrap assets" >/dev/null 2>&1
    git branch -M main
    git tag 2.8.2
    git remote add origin "file://$remote_dir"
    git push origin main --tags >/dev/null 2>&1
  )
}

prepare_sourced_script_run_dir() {
  local run_dir="$1"

  mkdir -p "$run_dir"
  cp "$SCRIPT_UNDER_TEST" "$run_dir/initBootstrap.sh"
  chmod +x "$run_dir/initBootstrap.sh"
}

run_script_functions() {
  local run_dir="$1"
  local remote_dir="$2"
  local script_body="$3"

  (
    cd "$run_dir"
    OPENSEARCH_MIGRATIONS_GIT_URL="file://$remote_dir" bash -c "source ./initBootstrap.sh && $script_body"
  )
}

test_invalid_tag_reports_clear_error() {
  local run_dir="$TEST_TMP_DIR/invalid-tag"
  local stub_dir="$run_dir/stubs"
  local output_file="$run_dir/output.log"

  mkdir -p "$run_dir"
  cp "$SCRIPT_UNDER_TEST" "$run_dir/initBootstrap.sh"
  chmod +x "$run_dir/initBootstrap.sh"
  make_stub_commands "$stub_dir"

  set +e
  (
    cd "$run_dir" &&
    PATH="$stub_dir:$PATH" ./initBootstrap.sh --tag definitely-not-a-real-tag > "$output_file" 2>&1
  )
  local exit_code=$?
  set -e

  if [[ $exit_code -eq 0 ]]; then
    echo "Expected invalid tag bootstrap to fail"
    exit 1
  fi

  assert_contains "Error: Git tag 'definitely-not-a-real-tag' was not found" "$output_file"
}

test_valid_tag_checkout_uses_tag_ref_without_pathspec_errors() {
  local remote_dir="$TEST_TMP_DIR/remote-valid-tag.git"
  local seed_dir="$TEST_TMP_DIR/seed-valid-tag"
  local run_dir="$TEST_TMP_DIR/run-valid-tag"
  local checkout_ref
  local expected_commit
  local head_commit

  create_test_remote "$remote_dir" "$seed_dir"
  prepare_sourced_script_run_dir "$run_dir"
  run_script_functions "$run_dir" "$remote_dir" "initialize_git_repository >/dev/null 2>&1; setup_origin_remote; fetch_origin_refs >/dev/null 2>&1" >/dev/null

  checkout_ref=$(run_script_functions "$run_dir" "$remote_dir" "resolve_tag_ref '2.8.2'")
  assert_equals "refs/tags/2.8.2" "$checkout_ref"

  run_script_functions "$run_dir" "$remote_dir" "validate_required_bootstrap_paths_in_ref '$checkout_ref' \"tag '2.8.2'\"; checkout_tag_ref '$checkout_ref' >/dev/null 2>&1"

  expected_commit=$(git --git-dir="$remote_dir" rev-parse "refs/tags/2.8.2^{commit}")
  head_commit=$(git -C "$run_dir" rev-parse HEAD)
  assert_equals "$expected_commit" "$head_commit"
}

test_missing_bootstrap_path_reports_clear_error() {
  local remote_dir="$TEST_TMP_DIR/remote-missing-path.git"
  local seed_dir="$TEST_TMP_DIR/seed-missing-path"
  local run_dir="$TEST_TMP_DIR/run-missing-path"
  local output_file="$TEST_TMP_DIR/missing-path.log"

  create_test_remote "$remote_dir" "$seed_dir"
  prepare_sourced_script_run_dir "$run_dir"
  run_script_functions "$run_dir" "$remote_dir" "initialize_git_repository >/dev/null 2>&1; setup_origin_remote; fetch_origin_refs >/dev/null 2>&1" >/dev/null

  set +e
  run_script_functions "$run_dir" "$remote_dir" "validate_required_bootstrap_paths_in_ref 'refs/tags/missing-path' \"tag 'missing-path'\"" > "$output_file" 2>&1
  local exit_code=$?
  set -e

  if [[ $exit_code -eq 0 ]]; then
    echo "Expected missing bootstrap path validation to fail"
    exit 1
  fi

  assert_contains "Error: Selected tag 'missing-path' is missing required bootstrap path 'deployment/cdk/opensearch-service-migration'." "$output_file"
}

test_branch_checkout_preserves_branch_bootstrap_flow() {
  local remote_dir="$TEST_TMP_DIR/remote-branch.git"
  local seed_dir="$TEST_TMP_DIR/seed-branch"
  local run_dir="$TEST_TMP_DIR/run-branch"
  local branch_ref
  local current_branch

  create_test_remote "$remote_dir" "$seed_dir"
  prepare_sourced_script_run_dir "$run_dir"
  run_script_functions "$run_dir" "$remote_dir" "initialize_git_repository >/dev/null 2>&1; setup_origin_remote; fetch_origin_refs >/dev/null 2>&1" >/dev/null

  branch_ref=$(run_script_functions "$run_dir" "$remote_dir" "resolve_branch_ref 'main'")
  assert_equals "refs/remotes/origin/main" "$branch_ref"

  run_script_functions "$run_dir" "$remote_dir" "validate_required_bootstrap_paths_in_ref '$branch_ref' \"branch 'main'\"; checkout_branch_ref 'main' '$branch_ref' >/dev/null 2>&1"

  current_branch=$(git -C "$run_dir" branch --show-current)
  assert_equals "main" "$current_branch"
}

test_invalid_tag_reports_clear_error
test_valid_tag_checkout_uses_tag_ref_without_pathspec_errors
test_missing_bootstrap_path_reports_clear_error
test_branch_checkout_preserves_branch_bootstrap_flow
echo "initBootstrap.sh tests passed"
