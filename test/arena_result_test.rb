require 'minitest/autorun'
require_relative '../ruby/arena_result'

class ArenaResultTest < Minitest::Test
  FIXTURES = File.expand_path('fixtures/arena', __dir__)
  T = "\t".freeze

  def played(id: 'g1', result: 'B+3.5', finish: 'passes', moves: %w[C3 D4 pass pass], length: moves.size,
             times: %w[0.012000 0.034000 0.050000])
    [id, "result=#{result}", "end=#{finish}", "length=#{length}", "time_black=#{times[0]}",
     "time_white=#{times[1]}", "duration=#{times[2]}", "moves=#{moves.join(',')}", 'ok'].join(T)
  end

  def errored(id: 'g1', side: 'black', message: 'x.ann does not fit a 9x9 board')
    [id, "error=#{side}", "message=#{message}", 'ok'].join(T)
  end

  def output(*lines, done: lines.size)
    (lines + (done ? ["done #{done}"] : [])).map { |l| "#{l}\n" }.join
  end

  def chunk(text, ids = ['g1'])
    ArenaResult.chunk(text, ids)
  end

  def result(line, ids = ['g1'])
    chunk(output(line), ids).results.fetch(ids.first)
  end

  def assert_no_result(result)
    assert_equal 'arena: no result', result.failure
    assert_nil result.winner
    refute result.crashed?
  end

  # Played games

  def test_black_wins
    r = result(played(result: 'B+3.5'))
    assert_equal :black, r.winner
    assert_nil r.failure
    refute r.crashed?
    assert_equal 'B+3.5', r.referee
    assert_nil r.error_message
  end

  def test_white_wins
    r = result(played(result: 'W+0.5'))
    assert_equal :white, r.winner
    assert_equal 'W+0.5', r.referee
  end

  def test_draw_has_no_winner_and_no_failure
    r = result(played(result: '0'))
    assert_nil r.winner
    assert_nil r.failure
    assert_equal '0', r.referee
  end

  def test_reads_length_times_and_moves
    r = result(played(moves: %w[C3 D4 pass pass], times: %w[0.012000 0.034000 0.050000]))
    assert_equal 4, r.length
    assert_in_delta 0.012, r.time_black
    assert_in_delta 0.034, r.time_white
    assert_in_delta 0.05, r.duration
    assert_equal %w[C3 D4 pass pass], r.moves
  end

  def test_move_limit_carries_the_gogui_message
    r = result(played(finish: 'limit', moves: %w[C3 D4 E5]))
    assert_equal :black, r.winner
    assert_equal 'move limit exceeded', r.error_message
    assert_nil r.failure
  end

  def test_two_passes_carry_no_message
    assert_nil result(played(finish: 'passes')).error_message
  end

  # Networks that cannot play

  def test_black_cannot_play_so_white_wins
    r = result(errored(side: 'black', message: 'b.ann: No such file or directory'))
    assert_equal :white, r.winner
    assert r.crashed?
    assert_nil r.failure
    assert_equal 'b.ann: No such file or directory', r.error_message
    assert_nil r.length
    assert_nil r.referee
    assert_empty r.moves
  end

  def test_white_cannot_play_so_black_wins
    r = result(errored(side: 'white'))
    assert_equal :black, r.winner
    assert r.crashed?
    assert_equal 'x.ann does not fit a 9x9 board', r.error_message
  end

  def test_neither_can_play_is_a_failure
    r = result(errored(side: 'both', message: 'a.ann is bad; b.ann is bad'))
    assert_nil r.winner
    refute r.crashed?
    assert_equal 'arena: neither network can play', r.failure
    assert_equal 'a.ann is bad; b.ann is bad', r.error_message
  end

  # Strictness

  def test_rejects_lines_that_are_not_exactly_the_format
    good = played
    bad = [
      good.sub("#{T}ok", ''),                              # no terminator
      "#{good}#{T}extra",                                  # extra field
      good.sub('result=B+3.5', 'result=B+3'),              # not B+N.N
      good.sub('result=B+3.5', 'result=B+R'),
      good.sub('result=B+3.5', 'result=X+3.5'),
      good.sub('end=passes', 'end=resign'),                # unknown end
      good.sub('length=4', 'length=four'),
      good.sub('length=4', 'length=5'),                    # length is not the move count
      good.sub('length=4', 'length=+4'),
      good.sub('time_black=0.012000', 'time_black=abc'),
      good.sub('time_black=0.012000', 'time_black=1e-3'),
      good.sub('moves=C3', 'moves=I3'),                    # GTP has no column I
      good.sub('moves=C3', 'moves=c3'),
      good.sub('moves=C3,D4', 'moves=C3,,D4'),
      good.sub(/time_black=\S+#{T}time_white=\S+/o, 'time_white=0.034000' + T + 'time_black=0.012000'), # order
      good.sub('duration=', 'wall='),                      # wrong name
      good.tr(T, ' '),                                     # not tab-separated
      errored.sub("#{T}ok", ''),
      errored.sub('error=black', 'error=red'),
      errored.sub('message=x.ann does not fit a 9x9 board', 'message='),
      'g1',
      'garbage'
    ]
    bad.each do |line|
      assert_no_result(chunk(output(line)).results.fetch('g1'))
    end
  end

  def test_truncated_last_line_is_no_result_but_earlier_lines_stand
    first = played(id: 'g1', result: 'W+2.5')
    cut = played(id: 'g2', result: 'B+35.5')[/\A.*result=B\+35/]
    text = "#{first}\n#{cut}"
    c = chunk(text, %w[g1 g2])
    refute c.complete?
    assert_equal :white, c.results.fetch('g1').winner
    assert_no_result c.results.fetch('g2')
  end

  def test_missing_trailer_keeps_valid_lines_and_fails_the_rest
    c = chunk(output(played(id: 'g1'), done: nil), %w[g1 g2 g3])
    refute c.complete?
    assert_equal :black, c.results.fetch('g1').winner
    assert_no_result c.results.fetch('g2')
    assert_no_result c.results.fetch('g3')
  end

  def test_trailer_count_must_match_the_schedule
    c = chunk(output(played(id: 'g1'), done: 2), %w[g1])
    refute c.complete?
    assert_equal :black, c.results.fetch('g1').winner
  end

  def test_complete_output
    c = chunk(output(played(id: 'a'), errored(id: 'b')), %w[a b])
    assert c.complete?
    assert_equal %w[a b], c.results.keys
  end

  def test_a_malformed_trailer_is_no_trailer
    ['done', 'done two', 'done 1 ', 'Done 1'].each do |trailer|
      refute chunk("#{played}\n#{trailer}\n").complete?, trailer
    end
  end

  def test_output_after_the_trailer_makes_it_incomplete
    c = chunk("#{played}\ndone 1\n#{played(id: 'g2')}\n", %w[g1])
    refute c.complete?
    assert_equal :black, c.results.fetch('g1').winner
  end

  def test_garbage_between_lines_makes_it_incomplete
    c = chunk(output(played(id: 'g1'), 'noise', played(id: 'g2'), done: 2), %w[g1 g2])
    refute c.complete?
    assert_equal :black, c.results.fetch('g2').winner
  end

  def test_empty_output_fails_every_game
    c = chunk('', %w[g1 g2])
    refute c.complete?
    assert_equal %w[g1 g2], c.results.keys
    c.results.each_value { |r| assert_no_result r }
  end

  def test_empty_schedule_with_trailer_is_complete
    assert chunk("done 0\n", []).complete?
  end

  # The arena never repeats an ID, so two lines for one game cannot say which
  # is true: the game has no result.
  def test_duplicate_lines_give_no_result
    c = chunk(output(played(id: 'g1', result: 'B+1.5'), played(id: 'g1', result: 'W+1.5')), %w[g1])
    refute c.complete?
    assert_no_result c.results.fetch('g1')
  end

  # A line for a game that was not scheduled means the output does not belong
  # to this schedule; it is ignored, and the chunk is not complete.
  def test_unexpected_id_is_ignored_and_incomplete
    c = chunk(output(played(id: 'g1'), played(id: 'zz')), %w[g1])
    refute c.complete?
    assert_equal ['g1'], c.results.keys
    assert_equal :black, c.results.fetch('g1').winner
  end

  def test_results_follow_schedule_order
    c = chunk(output(played(id: 'b'), played(id: 'a')), %w[a b])
    assert_equal %w[a b], c.results.keys
  end

  def test_accepts_a_trailer_without_a_newline
    c = chunk("#{played}\ndone 1", %w[g1])
    assert c.complete?
  end

  # SGF

  def fixture(name)
    File.read(File.join(FIXTURES, name))
  end

  def fixture_result(name)
    ArenaResult.chunk(fixture("#{name}.out"), [fixture("#{name}.out")[/\A\S+/]]).results.values.first
  end

  def move_nodes(sgf)
    sgf[/(;[BW]\[[a-z]*\])+/]
  end

  # The moves of a real twogtp game (engine/example.ann against itself, 9x9,
  # max_moves 30) and the arena's line for the same pairing.
  def test_sgf_moves_match_twogtp_on_9x9
    sgf = fixture_result('example_9x9').sgf(size: 9, komi: 6.5)
    assert_equal fixture('example_9x9.moves').chomp, move_nodes(sgf)
  end

  # A 5x5 game between seeded random networks, with passes.
  def test_sgf_moves_match_twogtp_with_passes
    sgf = fixture_result('passes_5x5').sgf(size: 5, komi: 6.5)
    assert_equal fixture('passes_5x5.moves').chomp, move_nodes(sgf)
  end

  def test_sgf_header
    r = result(played(result: 'W+7.5', moves: %w[C3 pass pass]))
    assert_equal '(;GM[1]FF[4]SZ[9]KM[6.5]RE[W+7.5];B[cg];W[];B[])', r.sgf(size: 9, komi: 6.5)
  end

  def test_sgf_corners_on_19x19
    r = result(played(moves: %w[T19 A1 J10 H10 A19 T1], finish: 'limit'))
    assert_equal '(;GM[1]FF[4]SZ[19]KM[-2.0]RE[B+3.5];B[sa];W[as];B[ij];W[hj];B[aa];W[ss])',
                 r.sgf(size: 19, komi: -2.0)
  end

  def test_sgf_rejects_a_vertex_off_the_board
    r = result(played(moves: %w[K3 pass pass]))
    assert_raises(ArgumentError) { r.sgf(size: 9, komi: 6.5) }
  end

  def test_no_sgf_without_a_game
    assert_nil result(errored).sgf(size: 9, komi: 6.5)
  end
end
