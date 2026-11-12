require 'minitest/autorun'
require 'fileutils'
require 'tmpdir'
require 'open3'

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

# Each subdirectory's Makefile must rebuild an object when a header it
# includes changes, or a stale object is linked: evolve/Makefile tracked
# only evolve.o's headers, engine/Makefile every object's but main.o's.
# Runs on a copy of each directory, with lib/ linked in and an empty
# pcg_variants.h, since the Ruby job in CI has no pcg-c submodule.
class MakefileDependenciesTest < Minitest::Test
  REPO = File.expand_path('..', __dir__)
  DIRS = %w[engine evolve initial-population].freeze

  def setup
    @dir = Dir.mktmpdir('makefile-deps-test')
    FileUtils.mkdir_p(File.join(@dir, 'pcg-c/include'))
    FileUtils.touch(File.join(@dir, 'pcg-c/include/pcg_variants.h'))
    File.symlink(File.join(REPO, 'lib'), File.join(@dir, 'lib'))
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  DIRS.each do |dir|
    define_method("test_every_#{dir.tr('-', '_')}_object_is_rebuilt_when_a_header_it_includes_changes") do
      copy = copy_sources(dir)
      objects = Dir.children(copy).grep(/\.c\z/).sort.map { |c| c.sub(/\.c\z/, '.o') }
      make(copy, '-s', *objects.map { |o| o.sub(/\.o\z/, '.dep') })
      # Every object exists and is newer than every source, so nothing needs
      # building until -W declares a header changed.
      later = Time.now + 3600
      objects.each { |o| FileUtils.touch(File.join(copy, o), mtime: later) }
      checked = 0
      objects.each do |object|
        assert_no_rebuild = make(copy, '-n', object)
        refute_includes assert_no_rebuild, "-c #{object.sub(/\.o\z/, '.c')}", "#{dir}/#{object} is not up to date"
        local_headers(copy, object.sub(/\.o\z/, '.c')).each do |header|
          out = make(copy, '-n', '-W', header, object)
          assert_includes out, "-o #{object} -c #{object.sub(/\.o\z/, '.c')}",
                          "#{dir}/#{object} is not rebuilt when #{header} changes"
          checked += 1
        end
      end
      assert_operator checked, :>, 0
    end
  end

  private

  def copy_sources(dir)
    copy = File.join(@dir, dir)
    FileUtils.mkdir(copy)
    Dir[File.join(REPO, dir, '{Makefile,*.c,*.h}')].each { |f| FileUtils.cp(f, copy) }
    copy
  end

  # The headers a source includes with quotes, as make names them: in its
  # own directory, or in lib/ through -I../lib.
  def local_headers(copy, source)
    File.read(File.join(copy, source)).scan(/^#include "([^"]+)"/).flatten.filter_map do |header|
      if File.exist?(File.join(copy, header)) then header
      elsif File.exist?(File.join(copy, '../lib', header)) then "../lib/#{header}"
      end
    end
  end

  def make(dir, *args)
    out, status = Open3.capture2e('make', *args, chdir: dir)
    assert status.success?, "make #{args.join(' ')} in #{dir} failed:\n#{out}"
    out
  end
end
