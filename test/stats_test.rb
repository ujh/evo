require 'minitest/autorun'
require 'csv'
require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'

# Runs the stats script with --csv on a small experiment built from the
# result fixtures. Each game is chosen so the old whitespace parsing, which
# counted anything but a Black win as a White win, gives a different answer.
class StatsTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  FIXTURES = File.join(ROOT, 'test/fixtures/dat')

  GAMES = {
    '0001xBrown1R0' => 'black_wins', # network beats the bot
    '0002xBrown1R0' => 'black_wins',
    '0002xBrown1R1' => 'black_wins',
    'Brown1x0001R1' => 'draw',        # nobody wins
    'Brown1x0002R2' => 'illegal_move' # failed game, with an empty column
  }.freeze

  def run_stats
    Dir.mktmpdir do |dir|
      generation = File.join(dir, 'experiments/x/0')
      FileUtils.mkdir_p(generation)
      FileUtils.mkdir_p(File.join(dir, 'experiments/x/1'))
      File.write(File.join(generation, 'data.json'), JSON.generate(
        'round' => 3,
        'players' => { '0001.ann' => {}, '0002.ann' => {}, 'Brown1' => { 'external' => true } },
        'ranking' => [{ 'name' => '0002.ann', 'score' => 2 }, { 'name' => 'Brown1', 'score' => 0 },
                      { 'name' => '0001.ann', 'score' => 1 }]
      ))
      GAMES.each do |prefix, fixture|
        %w[dat err].each do |ext|
          source = File.join(FIXTURES, "#{fixture}.#{ext}")
          FileUtils.cp(source, File.join(generation, "#{prefix}.#{ext}")) if File.exist?(source)
        end
      end
      env = { 'BUNDLE_GEMFILE' => File.join(ROOT, 'Gemfile') }
      out, err, status = Open3.capture3(env, 'ruby', File.join(ROOT, 'stats'), '--csv', 'x', chdir: dir)
      assert status.success?, err
      CSV.parse(out, headers: true).first
    end
  end

  def test_counts_only_real_network_wins_against_each_bot
    row = run_stats
    assert_equal '3', row['win_stats.Brown1.total']
    assert_equal '2', row['win_stats.Brown1.max']
  end

  def test_average_is_the_mean_not_the_median
    row = run_stats
    # The networks beat Brown1 once and twice.
    assert_equal '1.5', row['win_stats.Brown1.median']
    assert_equal '2', row['win_stats.Brown1.average']
  end

  def test_game_lengths_come_from_the_length_column
    row = run_stats
    assert_equal '2', row['game_length_stats.min']
    assert_equal '93', row['game_length_stats.max']
  end
end
