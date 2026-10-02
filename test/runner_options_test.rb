require 'minitest/autorun'
require_relative '../ruby/runner_options'

class RunnerOptionsTest < Minitest::Test
  def parse(*args)
    RunnerOptions.parse(args)
  end

  def refused(*args)
    assert_raises(RunnerOptions::Refused) { parse(*args) }.message
  end

  def test_the_defaults
    options = parse('demo')
    assert_equal ['demo', 2, false, nil],
                 [options.name, options.concurrency, options.one_generation, options.until_generation]
  end

  def test_every_option
    options = parse('demo', '--concurrency', '6', '--until-generation', '100')
    assert_equal ['demo', 6, false, 100],
                 [options.name, options.concurrency, options.one_generation, options.until_generation]
  end

  def test_options_may_come_before_the_name
    options = parse('--one-generation', '--concurrency=3', 'demo')
    assert_equal ['demo', 3, true], [options.name, options.concurrency, options.one_generation]
  end

  def test_until_generation_zero_is_allowed
    assert_equal 0, parse('demo', '--until-generation', '0').until_generation
  end

  def test_a_name_is_required
    assert_match(/Name of experiment required/, refused('--concurrency', '2'))
  end

  def test_the_old_positional_concurrency_is_refused
    assert_match(/One experiment name expected, got demo 4/, refused('demo', '4'))
  end

  def test_concurrency_must_be_a_whole_number_of_at_least_one
    %w[0 -1 1.5 two].each do |value|
      assert_match(/--concurrency must be a whole number of at least 1, got #{Regexp.escape(value)}/,
                   refused('demo', "--concurrency=#{value}"), value)
    end
  end

  def test_until_generation_must_be_a_whole_number_of_at_least_zero
    %w[-1 1.5 x].each do |value|
      assert_match(/--until-generation must be a whole number of at least 0, got #{Regexp.escape(value)}/,
                   refused('demo', "--until-generation=#{value}"), value)
    end
  end

  def test_one_generation_and_until_generation_exclude_each_other
    assert_match(/either --one-generation or --until-generation/,
                 refused('demo', '--one-generation', '--until-generation', '5'))
  end

  def test_an_unknown_option_is_refused
    assert_match(/invalid option: --fast/, refused('demo', '--fast'))
  end
end
