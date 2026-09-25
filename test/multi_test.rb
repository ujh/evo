require 'minitest/autorun'
require 'fileutils'
require 'open3'
require 'tmpdir'

# Runs the multi script with arguments it must reject, so it exits before its
# endless loop over the runner starts.
class MultiTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)

  def run_multi(*args)
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, 'experiments/present'))
      Open3.capture3('ruby', File.join(ROOT, 'multi'), *args, chdir: dir)
    end
  end

  def test_names_the_missing_experiment
    out, err, status = run_multi('1', 'present', 'missing')
    assert_equal 1, status.exitstatus
    assert_equal "missing is no experiment!\n", out
    assert_empty err
  end

  def test_requires_two_experiments
    out, _err, status = run_multi('1', 'present')
    assert_equal 1, status.exitstatus
    assert_equal "Specify at least two experiments!\n", out
  end
end
