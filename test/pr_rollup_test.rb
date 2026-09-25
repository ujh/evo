require 'minitest/autorun'
require 'json'
require 'open3'

# scripts/pr-rollup.jq decides whether `mise run pr-checks` reports a PR as
# green. These cases use the shape of `gh pr view --json
# headRefOid,mergeStateStatus,statusCheckRollup`.
class PrRollupTest < Minitest::Test
  FILTER = File.expand_path('../scripts/pr-rollup.jq', __dir__)
  HEAD = 'abc123'.freeze

  def check_run(conclusion, name: 'build-and-test', workflow: 'CI', started: '2026-09-24T19:03:47Z')
    { '__typename' => 'CheckRun', 'name' => name, 'workflowName' => workflow,
      'status' => conclusion.empty? ? 'IN_PROGRESS' : 'COMPLETED',
      'conclusion' => conclusion, 'startedAt' => started, 'completedAt' => '0001-01-01T00:00:00Z' }
  end

  def status_context(state, context: 'ci/external')
    { '__typename' => 'StatusContext', 'context' => context, 'state' => state,
      'startedAt' => '2026-09-24T19:03:47Z' }
  end

  def run_filter(rollup, head: HEAD, merge_state: 'CLEAN')
    input = JSON.generate('headRefOid' => head, 'mergeStateStatus' => merge_state, 'statusCheckRollup' => rollup)
    out, status = Open3.capture2('jq', '-rn', '--arg', 'head', HEAD, '-f', FILTER, stdin_data: input)
    assert status.success?, 'jq failed'
    out.lines(chomp: true)
  end

  def test_passing_checks_print_nothing
    assert_empty run_filter([check_run('SUCCESS'), check_run('SKIPPED', name: 'lint'),
                             check_run('NEUTRAL', name: 'info'), status_context('SUCCESS')])
  end

  def test_failed_check_run_is_reported
    assert_equal ["FAILURE\tbuild-and-test"], run_filter([check_run('FAILURE')])
  end

  def test_failed_status_context_is_reported
    assert_equal ["ERROR\tci/external"], run_filter([status_context('ERROR')])
  end

  def test_running_check_is_pending
    assert_equal ["PENDING\tbuild-and-test"], run_filter([check_run('')])
  end

  def test_blank_input_fails
    _out, status = Open3.capture2e('jq', '-rn', '--arg', 'head', HEAD, '-f', FILTER, stdin_data: " \n ")
    refute status.success?
  end

  def test_every_check_that_did_not_pass_is_listed
    assert_equal ["FAILURE\tbuild-and-test", "PENDING\tlint"],
                 run_filter([check_run('FAILURE'), check_run('', name: 'lint'), check_run('SUCCESS', name: 'docs')])
  end

  def test_branch_behind_main_is_reported_before_checks
    assert_equal ['BEHIND'], run_filter([check_run('SUCCESS')], merge_state: 'BEHIND')
  end

  def test_merge_conflicts_are_reported_before_checks
    assert_equal ['CONFLICTS'], run_filter([check_run('SUCCESS')], merge_state: 'DIRTY')
  end

  def test_unknown_merge_state_is_reported_once_checks_pass
    assert_equal ['MERGE STATE UNKNOWN'], run_filter([check_run('SUCCESS')], merge_state: 'UNKNOWN')
    assert_equal ["FAILURE\tbuild-and-test"], run_filter([check_run('FAILURE')], merge_state: 'UNKNOWN')
    assert_equal ['NO CHECKS'], run_filter([], merge_state: 'UNKNOWN')
  end

  def test_blocked_merge_is_reported_once_checks_pass
    assert_equal ['MERGE BLOCKED'], run_filter([check_run('SUCCESS')], merge_state: 'BLOCKED')
    assert_equal ["PENDING\tbuild-and-test"], run_filter([check_run('')], merge_state: 'BLOCKED')
  end

  def test_mergeable_state_passes
    assert_empty run_filter([check_run('SUCCESS')], merge_state: 'CLEAN')
  end

  def test_empty_or_missing_rollup_means_no_checks
    assert_equal ['NO CHECKS'], run_filter([])
    assert_equal ['NO CHECKS'], run_filter(nil)
  end

  def test_pr_at_another_commit_is_reported_first
    assert_equal ["HEAD MOVED\tdef456"], run_filter([check_run('SUCCESS')], head: 'def456')
  end

  def test_only_the_latest_run_of_a_rerun_check_counts
    old_failure = check_run('FAILURE', started: '2026-09-24T18:00:00Z')
    new_success = check_run('SUCCESS', started: '2026-09-24T19:00:00Z')
    assert_empty run_filter([old_failure, new_success])
    assert_equal ["FAILURE\tbuild-and-test"], run_filter([new_success.merge('startedAt' => '2026-09-24T17:00:00Z'), old_failure])
  end

  def test_queued_rerun_outranks_the_failure_it_replaces
    # gh reports a run that has not started with the zero time, not null.
    old_failure = check_run('FAILURE', started: '2026-09-24T19:00:00Z')
    queued = check_run('', started: '0001-01-01T00:00:00Z')
    assert_equal ["PENDING\tbuild-and-test"], run_filter([queued, old_failure])
    assert_equal ["PENDING\tbuild-and-test"], run_filter([old_failure, queued])
  end

  def test_same_check_name_in_two_workflows_counts_separately
    later_success = check_run('SUCCESS', workflow: 'Nightly', started: '2026-09-24T20:00:00Z')
    earlier_failure = check_run('FAILURE', workflow: 'CI', started: '2026-09-24T19:00:00Z')
    assert_equal ["FAILURE\tbuild-and-test"], run_filter([later_success, earlier_failure])
  end
end
