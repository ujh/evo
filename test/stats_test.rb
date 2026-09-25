require 'minitest/autorun'
require 'csv'
require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'
require_relative '../ruby/experiment_database'

# Runs the stats script with --csv on a small experiment whose games are in
# the experiment database. Draws and failed games count for nobody.
class StatsTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)

  def game(black, white, winner:, failure: nil, length: 93)
    { generation: 0, round: 0, black:, white:, black_external: black == 'Brown1', white_external: white == 'Brown1',
      winner:, failure:, length:, referee_result: nil, error_message: nil, stderr: nil, sgf: nil }
  end

  GAMES = [
    ['0001.ann', 'Brown1', { winner: '0001.ann' }],
    ['0002.ann', 'Brown1', { winner: '0002.ann' }],
    ['Brown1', '0001.ann', { winner: nil }], # draw
    ['Brown1', '0002.ann', { winner: nil, failure: 'error: Brown: illegal move', length: 2 }]
  ].freeze

  # Returns [CSV row for generation 0, files in the experiment before, after].
  def run_stats
    Dir.mktmpdir do |dir|
      experiment = File.join(dir, 'experiments/x')
      FileUtils.mkdir_p(File.join(experiment, '0'))
      FileUtils.mkdir_p(File.join(experiment, '1'))
      File.write(File.join(experiment, '0/data.json'), JSON.generate(
        'round' => 3,
        'players' => { '0001.ann' => {}, '0002.ann' => {}, 'Brown1' => { 'external' => true } },
        'ranking' => [{ 'name' => '0002.ann', 'score' => 2 }, { 'name' => 'Brown1', 'score' => 0 },
                      { 'name' => '0001.ann', 'score' => 1 }]
      ))
      store = ExperimentDatabase.new(File.join(experiment, 'experiment.sqlite3'))
      GAMES.each { |black, white, outcome| store.record(**game(black, white, **outcome)) }
      # Rounds are part of the key, so the second game against the same
      # opponent goes in another round.
      store.record(**game('0002.ann', 'Brown1', winner: '0002.ann').merge(round: 1))
      store.close

      before = Dir.glob('**/*', base: experiment).sort
      env = { 'BUNDLE_GEMFILE' => File.join(ROOT, 'Gemfile') }
      out, err, status = Open3.capture3(env, 'ruby', File.join(ROOT, 'stats'), '--csv', 'x', chdir: dir)
      assert status.success?, err
      [CSV.parse(out, headers: true).first, before, Dir.glob('**/*', base: experiment).sort]
    end
  end

  def test_counts_only_real_network_wins_against_each_bot
    row, = run_stats
    assert_equal '3', row['win_stats.Brown1.total']
    assert_equal '2', row['win_stats.Brown1.max']
  end

  def test_average_is_the_mean_not_the_median
    row, = run_stats
    # The networks beat Brown1 once and twice.
    assert_equal '1.5', row['win_stats.Brown1.median']
    assert_equal '2', row['win_stats.Brown1.average']
  end

  def test_game_lengths_come_from_the_stored_games
    row, = run_stats
    assert_equal '2', row['game_length_stats.min']
    assert_equal '93', row['game_length_stats.max']
  end

  def test_stats_writes_and_deletes_nothing
    _row, before, after = run_stats
    assert_equal before, after
  end
end
