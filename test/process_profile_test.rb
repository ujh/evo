require 'minitest/autorun'
require 'rbconfig'
require 'tmpdir'
require_relative '../ruby/process_profile'

class ProcessProfileTest < Minitest::Test
  def test_line_reports_cpu_times_and_gc_totals_in_a_fixed_order
    times = Process::Tms.new(1.25, 0.5, 30.0, 4.125)
    gc = { count: 12, minor_gc_count: 10, major_gc_count: 2, time: 345,
           total_allocated_objects: 1_000_000, total_freed_objects: 900_000,
           heap_live_slots: 100_000, other: 7 }

    assert_equal 'profile utime=1.250 stime=0.500 child_utime=30.000 child_stime=4.125 ' \
                 'gc_count=12 minor_gc_count=10 major_gc_count=2 gc_time_ms=345 ' \
                 'total_allocated_objects=1000000 total_freed_objects=900000 heap_live_slots=100000',
                 ProcessProfile.line(times, gc)
  end

  # The runner leaves through exit with a status on every path, so the
  # profile must be written then too.
  def test_install_writes_the_line_when_the_process_exits
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'profile.txt')
      library = File.expand_path('../ruby/process_profile', __dir__)
      # Well above the objects Ruby allocates while booting, so a profile
      # written at install instead of at exit shows too few.
      script = "require #{library.dump}; ProcessProfile.install(#{path.dump}); 500_000.times { Object.new }; exit 3"

      system(RbConfig.ruby, '-e', script)

      assert_equal 3, $?.exitstatus
      line = File.read(path)
      assert_match(/\Aprofile utime=\d+\.\d{3} stime=\d+\.\d{3} child_utime=\d+\.\d{3} child_stime=\d+\.\d{3} gc_count=\d+ /, line)
      assert_operator line[/total_allocated_objects=(\d+)/, 1].to_i, :>=, 500_000
      assert line.end_with?("\n")
    end
  end

  RUNNER = File.expand_path('../runner', __dir__)

  # Runs the runner without an experiment name, so it exits at once, with
  # `env`; returns its stderr and exit status.
  def run_runner(env)
    reader, writer = IO.pipe
    pid = Process.spawn(env, RbConfig.ruby, RUNNER, out: File::NULL, err: writer, chdir: File.dirname(RUNNER))
    writer.close
    stderr = reader.read
    Process.wait(pid)
    [stderr, $?.exitstatus]
  end

  def test_the_runner_writes_a_profile_when_evo_profile_is_set
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'profile.txt')

      stderr, status = run_runner('EVO_PROFILE' => path)

      assert_equal ['', 1], [stderr, status]
      assert_match(/\Aprofile utime=/, File.read(path))
    end
  end

  def test_the_runner_writes_no_profile_without_evo_profile
    Dir.mktmpdir do |dir|
      [{ 'EVO_PROFILE' => nil }, { 'EVO_PROFILE' => '' }].each do |env|
        stderr, status = run_runner(env)

        assert_equal ['', 1], [stderr, status], env.inspect
      end
      assert_empty Dir.children(dir)
    end
  end
end
