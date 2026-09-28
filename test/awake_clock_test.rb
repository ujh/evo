require 'minitest/autorun'
require_relative '../ruby/awake_clock'

class AwakeClockTest < Minitest::Test
  # Stand in for Process on macOS, which has both clocks, and on Linux,
  # which has no CLOCK_UPTIME_RAW.
  MACOS = Module.new.tap do |m|
    m.const_set(:CLOCK_MONOTONIC, 6)
    m.const_set(:CLOCK_UPTIME_RAW, 8)
  end
  LINUX = Module.new.tap { |m| m.const_set(:CLOCK_MONOTONIC, 1) }

  def test_uses_the_clock_that_stops_during_sleep_where_there_is_one
    assert_equal 8, AwakeClock.id(MACOS)
    assert_equal 1, AwakeClock.id(LINUX)
  end

  def test_reads_that_clock_in_seconds
    assert_equal AwakeClock.id(Process), AwakeClock::ID
    before = Process.clock_gettime(AwakeClock::ID)
    now = AwakeClock.now
    assert_operator now, :>=, before
    assert_operator now - before, :<, 1
  end
end
