require 'minitest/autorun'
require 'fileutils'
require 'tmpdir'

# The top-level Makefile in a fresh worktree, whose pcg-c submodule is empty
# until `git submodule update --init` fills it. A recipe that changes into a
# missing directory and runs make anyway runs the top-level Makefile again,
# without end, so each target must fail at once instead.
class MakefileTest < Minitest::Test
  ROOT_MAKEFILE = File.expand_path('../Makefile', __dir__)
  SUBDIRS = %w[engine initial-population evolve lib].freeze
  SUBDIR_TARGETS = %w[all clean test enginetest arenatest evolvetest perturbtest].freeze
  # Long enough for one failing make on a loaded machine; the recursion
  # reached make[582] in 8 seconds.
  DEADLINE = 20

  def setup
    @dir = Dir.mktmpdir('makefile-test')
    FileUtils.cp(ROOT_MAKEFILE, @dir)
    FileUtils.mkdir(File.join(@dir, 'pcg-c'))
    SUBDIRS.each do |sub|
      FileUtils.mkdir(File.join(@dir, sub))
      rules = SUBDIR_TARGETS.map { |target| "#{target}:\n\t@echo #{sub} #{target}\n" }
      File.write(File.join(@dir, sub, 'Makefile'), rules.join)
    end
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def test_the_default_target_fails_without_recursing_when_pcg_is_missing
    assert_fails_on_missing_pcg
  end

  def test_test_fails_without_recursing_when_pcg_is_missing
    assert_fails_on_missing_pcg('test')
  end

  def test_clean_cleans_the_subdirectories_then_fails_without_recursing_when_pcg_is_missing
    output = assert_fails_on_missing_pcg('clean')
    SUBDIRS.each { |sub| assert_includes output, "#{sub} clean" }
  end

  private

  # Runs make in its own process group, so a recursion that outlives the
  # deadline can be killed with every make it started.
  def run_make(*targets)
    reader, writer = IO.pipe
    pid = Process.spawn('make', *targets, chdir: @dir, out: writer, err: writer, pgroup: true)
    writer.close
    output = +''
    collector = Thread.new { output << reader.read }
    status = wait_until_deadline(pid)
    collector.join
    reader.close
    [status, output]
  end

  def wait_until_deadline(pid)
    deadline = Time.now + DEADLINE
    while Time.now < deadline
      _, status = Process.wait2(pid, Process::WNOHANG)
      return status if status

      sleep 0.05
    end
    Process.kill('KILL', -pid)
    Process.wait(pid)
    nil
  end

  def assert_fails_on_missing_pcg(*targets)
    status, output = run_make(*targets)
    refute_nil status, "make #{targets.join(' ')} still ran after #{DEADLINE} s:\n#{output[-2000..] || output}"
    refute status.success?, "make #{targets.join(' ')} succeeded without pcg-c/src:\n#{output}"
    assert_includes output, 'pcg-c/src'
    refute_match(/make\[2\]/, output, 'make ran the top-level Makefile again')
    output
  end
end
