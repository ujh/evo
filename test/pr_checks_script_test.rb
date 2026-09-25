require 'minitest/autorun'
require_relative 'fake_gh'

# Runs scripts/pr-checks.sh end to end against a fake gh.
class PrChecksScriptTest < Minitest::Test
  include FakeGh

  FAST = { 'PR_CHECKS_TRIES' => '2', 'PR_CHECKS_SLEEP' => '0' }.freeze

  def head
    @head ||= `git rev-parse HEAD`.strip
  end

  def success(name = 'build-and-test')
    { 'name' => name, 'workflowName' => 'CI', 'status' => 'COMPLETED', 'conclusion' => 'SUCCESS',
      'startedAt' => '2026-09-24T19:03:47Z' }
  end

  def view(rollup, head_ref: head, merge_state: 'CLEAN')
    { 'headRefOid' => head_ref, 'mergeStateStatus' => merge_state, 'statusCheckRollup' => rollup }
  end

  def run_checks(*views)
    run_with_fake_gh('pr-checks.sh', '7', views: views, env: FAST)
  end

  def test_green_checks_on_head_pass
    out, _err, status = run_checks(view([success]))
    assert_equal 0, status
    assert_includes out, "All checks passed on #{head}"
  end

  def test_failed_check_fails
    out, err, status = run_checks(view([success.merge('conclusion' => 'FAILURE')]))
    assert_equal 1, status
    assert_includes err, "FAILURE\tbuild-and-test"
    refute_includes out, 'All checks passed'
  end

  def test_check_still_pending_after_the_watch_fails
    out, err, status = run_checks(view([success.merge('status' => 'IN_PROGRESS', 'conclusion' => '')]))
    assert_equal 1, status
    assert_includes err, "Checks that did not pass on #{head}:\nPENDING\tbuild-and-test"
    refute_includes out, 'All checks passed'
  end

  def test_blank_gh_output_fails_instead_of_reading_as_green
    out, _err, status = run_checks(" \n ")
    refute_equal 0, status
    refute_includes out, 'All checks passed'
  end

  def test_pr_at_another_commit_fails
    _out, err, status = run_checks(view([success], head_ref: 'def456'))
    assert_equal 1, status
    assert_includes err, 'PR 7 is at def456'
  end

  def test_branch_behind_main_fails_with_how_to_update
    out, err, status = run_checks(view([success], merge_state: 'BEHIND'))
    assert_equal 1, status
    assert_includes err, 'PR 7 is behind main'
    assert_includes err, 'gh pr update-branch 7'
    refute_includes out, 'All checks passed'
  end

  def test_merge_conflicts_fail
    out, err, status = run_checks(view([success], merge_state: 'DIRTY'))
    assert_equal 1, status
    assert_includes err, 'PR 7 has merge conflicts with main'
    refute_includes out, 'All checks passed'
  end

  def test_asks_again_while_github_computes_the_merge_state
    unknown = view([success], merge_state: 'UNKNOWN')
    out, _err, status = run_checks(unknown, unknown, view([success]))
    assert_equal 0, status
    assert_includes out, 'All checks passed'
  end

  def test_merge_state_that_stays_unknown_fails
    out, err, status = run_checks(view([success], merge_state: 'UNKNOWN'))
    assert_equal 1, status
    assert_includes err, 'GitHub has not worked out whether PR 7 is up to date with main'
    refute_includes out, 'All checks passed'
  end

  def test_asks_again_while_github_still_blocks_after_checks_pass
    blocked = view([success], merge_state: 'BLOCKED')
    out, _err, status = run_checks(blocked, blocked, view([success]))
    assert_equal 0, status
    assert_includes out, 'All checks passed'
  end

  def test_merge_that_stays_blocked_fails
    out, err, status = run_checks(view([success], merge_state: 'BLOCKED'))
    assert_equal 1, status
    assert_includes err, 'GitHub blocks merging PR 7 although every check passed'
    refute_includes out, 'All checks passed'
  end

  def test_waits_for_github_to_see_a_fresh_push
    out, _err, status = run_checks(view([success], head_ref: 'old123'), view([success]))
    assert_equal 0, status
    assert_includes out, 'All checks passed'
  end

  def test_gh_failure_fails_instead_of_reading_as_green
    out, err, status = run_checks
    refute_equal 0, status
    assert_includes err, 'Could not resolve'
    refute_includes out, 'All checks passed'
  end

  def test_empty_gh_output_fails_instead_of_reading_as_green
    out, err, status = run_checks('')
    assert_equal 1, status
    assert_includes err, 'gh pr view returned nothing for PR 7'
    refute_includes out, 'All checks passed'
  end

  def test_checks_that_never_register_time_out
    out, err, status = run_checks(view([]))
    assert_equal 1, status
    assert_includes err, 'No checks registered for PR 7'
    refute_includes out, 'All checks passed'
  end

  def test_waits_for_checks_to_register
    out, _err, status = run_checks(view([]), view([success]))
    assert_equal 0, status
    assert_includes out, 'All checks passed'
  end
end
