require 'minitest/autorun'
require 'json'
require 'open3'
require 'tmpdir'

# Runs scripts/pr-checks.sh end to end against a fake `gh` on PATH. The fake
# answers `gh pr view` from $FAKE_GH_VIEW (or fails when it is unset) and
# treats `gh pr checks --watch` as finished.
class PrChecksScriptTest < Minitest::Test
  SCRIPT = File.expand_path('../scripts/pr-checks.sh', __dir__)
  FAKE_GH = <<~SH.freeze
    #!/bin/sh
    case "$1 $2" in
      'pr view')
        [ -n "${FAKE_GH_VIEW:-}" ] || { echo 'GraphQL: Could not resolve to a PullRequest' >&2; exit 1; }
        cat "$FAKE_GH_VIEW"
        ;;
      'pr checks') exit 0 ;;
      *) echo "unexpected gh call: $*" >&2; exit 2 ;;
    esac
  SH

  def head
    @head ||= `git rev-parse HEAD`.strip
  end

  def success(name = 'build-and-test')
    { 'name' => name, 'workflowName' => 'CI', 'status' => 'COMPLETED', 'conclusion' => 'SUCCESS',
      'startedAt' => '2026-09-24T19:03:47Z' }
  end

  # Returns [stdout, stderr, exit status] of the script under `sh`.
  def run_script(view)
    Dir.mktmpdir('evo-fake-gh') do |dir|
      File.write(File.join(dir, 'gh'), FAKE_GH)
      File.chmod(0o755, File.join(dir, 'gh'))
      env = { 'PATH' => "#{dir}:#{ENV.fetch('PATH')}" }
      if view
        File.write(File.join(dir, 'view.json'), JSON.generate(view))
        env['FAKE_GH_VIEW'] = File.join(dir, 'view.json')
      end
      out, err, status = Open3.capture3(env, 'sh', SCRIPT, '7')
      [out, err, status.exitstatus]
    end
  end

  def test_green_checks_on_head_pass
    out, _err, status = run_script('headRefOid' => head, 'statusCheckRollup' => [success])
    assert_equal 0, status
    assert_includes out, "All checks passed on #{head}"
  end

  def test_failed_check_fails
    failed = success.merge('conclusion' => 'FAILURE')
    out, err, status = run_script('headRefOid' => head, 'statusCheckRollup' => [failed])
    assert_equal 1, status
    assert_includes err, "FAILURE\tbuild-and-test"
    refute_includes out, 'All checks passed'
  end

  def test_pr_at_another_commit_fails
    _out, err, status = run_script('headRefOid' => 'def456', 'statusCheckRollup' => [success])
    assert_equal 1, status
    assert_includes err, 'PR 7 is at def456'
  end

  def test_gh_failure_fails_instead_of_reading_as_green
    out, err, status = run_script(nil)
    refute_equal 0, status
    assert_includes err, 'Could not resolve'
    refute_includes out, 'All checks passed'
  end
end
