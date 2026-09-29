require 'minitest/autorun'
require_relative '../ruby/arena_result'

# The output of `arena --mixed` (see engine/arena.c), read a line at a time
# by ArenaResult::MixedStream, as the runner gets it from the pool. The
# fixtures are real output of
# `arena --mixed 9 6.5 30 MAIN 10 10 MANIFEST` with engine/example.ann and
# engine/fakebot (MAIN 600, or 0.000001 for mixed_time and 0.2 with grace
# 0 for mixed_timeout; fakebot rules such as genmove=ok:resign,
# genmove#2=hang, genmove#2=ok:Z9, genmove#3=crash), the temporary paths
# in messages replaced by /tmp/evo.
class ArenaMixedResultTest < Minitest::Test
  FIXTURES = File.expand_path('fixtures/arena', __dir__)
  T = "\t".freeze
  HEADER = 'arena protocol 3 ready'.freeze

  # The games of mixed_played.out, in manifest order.
  PLAYED = %w[played resign0 resign1 botpass noload].freeze

  def fixture(name)
    File.read(File.join(FIXTURES, "mixed_#{name}.out"))
  end

  # The stream after reading each line of `text`, split as WorkerPool
  # splits a streaming job's stdout.
  def chunk(text, ids = ['g1'])
    stream = ArenaResult::MixedStream.new(ids)
    lines = text.b.split("\n", -1)
    lines.pop if lines.last == ''
    lines.each { |line| stream.add(line) }
    stream
  end

  def assert_broken(text, ids, says)
    error = assert_raises(ArenaResult::Broken, text) { chunk(text, ids) }
    assert_equal says, error.message, text
  end

  def played(id: 'g1', result: 'B+3.5', finish: 'passes', moves: %w[C3 D4 pass pass], length: moves.size,
             times: %w[0.012000 0.034000 0.050000])
    [id, "result=#{result}", "end=#{finish}", "length=#{length}", "time_black=#{times[0]}",
     "time_white=#{times[1]}", "duration=#{times[2]}", "moves=#{moves.join(',')}", 'ok'].join(T)
  end

  def network_error(id: 'g1', side: 'black', message: 'cannot open x.ann')
    [id, 'end=network_error', "error=#{side}", "message=#{message}", 'ok'].join(T)
  end

  def failed(id: 'g1', finish: 'timeout', side: 'white', moves: %w[D4 pass F6], length: moves.size,
             times: %w[0.000005 0.203209 0.204628], message: 'genmove: no answer to genmove within 0.200 s')
    [id, "end=#{finish}", "error=#{side}", "length=#{length}", "time_black=#{times[0]}", "time_white=#{times[1]}",
     "duration=#{times[2]}", "moves=#{moves.join(',')}", "message=#{message}", 'ok'].join(T)
  end

  def output(*lines, header: true, done: lines.size)
    ((header ? [HEADER] : []) + lines + (done ? ["done #{done}"] : [])).map { |l| "#{l}\n" }.join
  end

  def result(line, ids = ['g1'])
    chunk(output(line), ids).results.fetch(ids.first)
  end

  def assert_no_result(result)
    assert_equal ArenaResult::NO_RESULT, result.failure
    assert_nil result.winner
    assert_nil result.end_reason
    refute result.failed?
    refute result.crashed?
  end

  def assert_stored(result)
    assert_nil result.failure
    refute result.failed?
  end

  # A chunk with a played game, bot resignations before any move and after
  # one, a bot that passes, and a network that cannot be loaded.
  def test_a_complete_chunk_of_real_output
    c = chunk(fixture('played'), PLAYED)
    assert c.header?
    assert c.complete?
    assert_equal 5, c.trailer
    assert_empty c.failures
    assert_empty c.missing
    assert_equal PLAYED, c.results.keys
    c.results.each_value { |r| assert_stored r }
  end

  def test_a_move_limit_game
    r = chunk(fixture('played'), PLAYED).results.fetch('played')
    assert_equal :white, r.winner
    assert_equal 'W+5.5', r.referee
    assert_equal 'limit', r.end_reason
    assert_equal 'move limit exceeded', r.error_message
    assert_equal 31, r.length
    assert_equal 31, r.moves.size
    assert_equal 'D4', r.moves.first
    assert_in_delta 0.000009, r.time_black
    assert_in_delta 0.000008, r.time_white
    assert_in_delta 0.000026, r.duration
    assert_nil r.error_side
  end

  def test_a_game_ended_by_two_passes
    r = result(played(result: 'W+0.5', finish: 'passes'))
    assert_equal :white, r.winner
    assert_equal 'passes', r.end_reason
    assert_nil r.error_message
    assert_stored r
  end

  def test_a_draw
    r = result(played(result: '0'))
    assert_nil r.winner
    assert_equal '0', r.referee
    assert_stored r
  end

  # Black's bot resigned at its first genmove: white wins without a move.
  def test_a_resignation_before_any_move
    r = chunk(fixture('played'), PLAYED).results.fetch('resign0')
    assert_equal :white, r.winner
    assert_equal 'W+R', r.referee
    assert_equal 'resign', r.end_reason
    assert_equal 0, r.length
    assert_empty r.moves
    assert_nil r.error_message
    refute r.crashed?
    assert_equal '(;GM[1]FF[4]SZ[9]KM[6.5]RE[W+R])', r.sgf(size: 9, komi: 6.5)
  end

  def test_a_resignation_after_a_move
    r = chunk(fixture('played'), PLAYED).results.fetch('resign1')
    assert_equal :black, r.winner
    assert_equal 'B+R', r.referee
    assert_equal 'resign', r.end_reason
    assert_equal %w[D4], r.moves
    assert_equal '(;GM[1]FF[4]SZ[9]KM[6.5]RE[B+R];B[df])', r.sgf(size: 9, komi: 6.5)
  end

  # Black's network ran out of main time on its first move, which is kept.
  def test_a_time_loss_on_the_first_move
    c = chunk(fixture('time'), %w[time1])
    assert c.complete?
    r = c.results.fetch('time1')
    assert_equal :white, r.winner
    assert_equal 'W+T', r.referee
    assert_equal 'time', r.end_reason
    assert_equal 1, r.length
    assert_nil r.error_message
    assert_stored r
    assert_equal '(;GM[1]FF[4]SZ[9]KM[6.5]RE[W+T];B[df])', r.sgf(size: 9, komi: 6.5)
  end

  def test_a_time_loss_by_white
    r = result(played(result: 'B+T', finish: 'time', moves: %w[C3 D4]))
    assert_equal :black, r.winner
    assert_equal 'time', r.end_reason
    assert_equal '(;GM[1]FF[4]SZ[9]KM[6.5]RE[B+T];B[cg];W[df])', r.sgf(size: 9, komi: 6.5)
  end

  # A network that cannot be loaded loses, as with the legacy invocation.
  def test_a_network_that_cannot_be_loaded_loses
    r = chunk(fixture('played'), PLAYED).results.fetch('noload')
    assert_equal :black, r.winner
    assert r.crashed?
    assert_stored r
    assert_equal 'network_error', r.end_reason
    assert_equal :white, r.error_side
    assert_equal 'cannot open /tmp/evo/missing.ann', r.error_message
    assert_nil r.length
    assert_nil r.referee
    assert_empty r.moves
    assert_nil r.sgf(size: 9, komi: 6.5)
  end

  def test_black_network_that_cannot_be_loaded_loses
    r = result(network_error(side: 'black'))
    assert_equal :white, r.winner
    assert_equal :black, r.error_side
    assert r.crashed?
  end

  # Failure records

  # A bot timed out in the second game: the first game stands, the arena
  # stopped, and the third game has no record.
  def test_a_timeout_stops_the_chunk
    c = chunk(fixture('timeout'), %w[first g after])
    assert c.header?
    refute c.complete?
    assert_nil c.trailer
    assert_equal :white, c.results.fetch('first').winner
    assert_stored c.results.fetch('first')
    assert_equal %w[g], c.failures.keys
    assert_equal %w[after], c.missing
    assert_no_result c.results.fetch('after')

    r = c.failures.fetch('g')
    assert_same r, c.results.fetch('g')
    assert r.failed?
    assert_nil r.winner
    refute r.crashed?
    refute_nil r.failure
    assert_equal 'timeout', r.end_reason
    assert_equal :white, r.error_side
    assert_equal 'genmove: no answer to genmove within 0.200 s', r.error_message
    assert_equal 3, r.length
    assert_equal %w[D4 pass F6], r.moves
    assert_in_delta 0.000005, r.time_black
    assert_in_delta 0.203209, r.time_white
    assert_in_delta 0.204628, r.duration
    assert_nil r.referee
    assert_nil r.sgf(size: 9, komi: 6.5)
  end

  def test_an_illegal_move
    r = chunk(fixture('illegal'), %w[g]).failures.fetch('g')
    assert_equal 'illegal', r.end_reason
    assert_equal :black, r.error_side
    assert_equal "genmove answered 'Z9', which is not a move on a 9x9 board", r.error_message
    assert_equal %w[pass D4], r.moves
  end

  def test_a_crash
    r = chunk(fixture('crash'), %w[g]).failures.fetch('g')
    assert_equal 'crash', r.end_reason
    assert_equal :white, r.error_side
    assert_equal 'genmove: killed by signal 11', r.error_message
    assert_equal 5, r.length
  end

  def test_a_launch_failure_has_no_moves
    r = chunk(fixture('launch'), %w[g]).failures.fetch('g')
    assert_equal 'launch', r.end_reason
    assert_equal :black, r.error_side
    assert_equal 'cannot start /tmp/evo/nosuchbot: No such file or directory', r.error_message
    assert_equal 0, r.length
    assert_empty r.moves
    assert_in_delta 0.000493, r.duration
  end

  def test_neither_network_can_be_loaded
    c = chunk(fixture('both'), %w[g])
    r = c.failures.fetch('g')
    assert r.failed?
    assert_equal ArenaResult::NEITHER_PLAYS, r.failure
    assert_equal 'network_error', r.end_reason
    assert_equal :both, r.error_side
    assert_nil r.winner
    refute r.crashed?
    assert_match(/\Acannot open .*; cannot open /, r.error_message)
  end

  def test_each_failure_names_its_reason_and_side
    %w[timeout illegal crash launch].each do |finish|
      %w[black white].each do |side|
        r = result(failed(finish:, side:))
        assert r.failed?, finish
        assert_equal finish, r.end_reason
        assert_equal side.to_sym, r.error_side
        assert_includes r.failure, finish
      end
    end
  end

  # The arena exits after a failure record; one before the trailer is
  # still a failure, however complete the chunk is.
  def test_a_failure_in_a_complete_chunk_is_still_a_failure
    c = chunk(output(played(id: 'a'), failed(id: 'b')), %w[a b])
    assert c.complete?
    assert_equal %w[b], c.failures.keys
    assert_empty c.missing
  end

  # Invalid UTF-8 from a bot's message does not break the chunk.
  def test_a_message_with_invalid_utf8
    text = output(failed(message: "genmove answered 'caf\xE9'")).b
    r = chunk(text).failures.fetch('g1')
    assert_equal "genmove answered 'caf�'", r.error_message
    assert_equal Encoding::UTF_8, r.error_message.encoding

    utf8 = output(network_error(message: "bad \xFF name")).force_encoding(Encoding::UTF_8)
    assert_equal "bad � name", chunk(utf8).results.fetch('g1').error_message
  end

  # Strictness

  def test_rejects_records_that_are_not_exactly_the_format
    good = played
    fail_line = failed
    bad = [
      good.sub("#{T}ok", ''),
      "#{good}#{T}extra",
      good.sub('result=B+3.5', 'result=B+3'),
      good.sub('result=B+3.5', 'result=X+3.5'),
      good.sub('result=B+3.5', 'result=B+X'),
      good.sub('result=B+3.5', 'result=B+R'),                  # a resignation ending by passes
      good.sub('result=B+3.5', 'result=W+T'),                  # a time loss ending by passes
      good.sub('end=passes', 'end=resign'),                    # a score for a resignation
      good.sub('end=passes', 'end=time'),                      # a score for a time loss
      good.sub('end=passes', 'end=timeout'),
      good.sub('end=passes', 'end=network_error'),
      good.sub('length=4', 'length=5'),
      good.sub('length=4', 'length=+4'),
      good.sub('time_black=0.012000', 'time_black=1e-3'),
      good.sub('moves=C3', 'moves=I3'),
      good.sub('moves=C3', 'moves=c3'),
      good.sub('moves=C3,D4', 'moves=C3,,D4'),
      good.sub('moves=C3,D4,pass,pass', 'moves=C3,D4,PASS,pass'),
      good.tr(T, ' '),
      network_error.sub("#{T}ok", ''),
      network_error.sub('error=black', 'error=red'),
      network_error.sub('message=cannot open x.ann', 'message='),
      network_error.sub('end=network_error', 'end=launch'),
      network_error.sub("end=network_error#{T}", ''),          # the legacy line
      fail_line.sub("#{T}ok", ''),
      fail_line.sub('end=timeout', 'end=network_error'),
      fail_line.sub('end=timeout', 'end=passes'),
      fail_line.sub('end=timeout', 'end=hang'),
      fail_line.sub('error=white', 'error=both'),
      fail_line.sub('error=white', 'error=red'),
      fail_line.sub('length=3', 'length=2'),
      fail_line.sub('moves=D4', 'moves=d4'),
      fail_line.sub('time_white=0.203209', 'time_white=0.2'),
      fail_line.sub(/message=[^\t]*/, 'message='),
      fail_line.sub(/#{T}message=[^\t]*/o, ''),
      fail_line.sub("#{T}time_black=0.000005", ''),
      HEADER,
      'done 1',
      'g1',
      'garbage'
    ]
    bad.each do |line|
      c = chunk(output(line))
      refute c.complete?, line
      assert_empty c.failures, line
      assert_equal ['g1'], c.missing, line
      assert_no_result c.results.fetch('g1')
    end
  end

  # Who wins by resignation or on time follows from who was to move: black
  # moves first, so after an even number of moves it is black's turn.
  def test_the_winner_must_fit_whose_turn_it_was
    {
      ['W+R', 'resign', 0] => true, ['W+R', 'resign', 2] => true,
      ['B+R', 'resign', 1] => true, ['B+R', 'resign', 3] => true,
      ['B+R', 'resign', 0] => false, ['B+R', 'resign', 2] => false,
      ['W+R', 'resign', 1] => false, ['W+R', 'resign', 3] => false,
      ['W+T', 'time', 1] => true, ['W+T', 'time', 3] => true,
      ['B+T', 'time', 2] => true, ['B+T', 'time', 4] => true,
      ['W+T', 'time', 2] => false, ['B+T', 'time', 1] => false,
      ['B+T', 'time', 0] => false, ['W+T', 'time', 0] => false
    }.each do |(referee, finish, length), valid|
      r = result(played(result: referee, finish:, moves: Array.new(length, 'pass')))
      if valid
        assert_equal referee, r.referee, [referee, length].inspect
      else
        assert_no_result r
      end
    end
  end

  # The arena writes the header before any record, so a record without one
  # before it means an arena that cannot be trusted: the runner stops.
  def test_a_record_before_the_header_is_broken
    assert_broken(output(played, header: false), ['g1'], 'wrote a record before its header')
  end

  def test_the_header_must_come_first_and_be_exact
    ["#{played}\n#{HEADER}\ndone 1\n", "arena protocol 2 ready\n#{played}\ndone 1\n",
     "#{HEADER} \n#{played}\ndone 1\n", "\n#{HEADER}\n#{played}\ndone 1\n"].each do |text|
      assert_broken(text, ['g1'], 'wrote a record before its header')
    end
    ["arena protocol 2 ready\n", "\n#{HEADER}\ndone 0\n"].each do |text|
      c = chunk(text, [])
      refute c.header?, text
      refute c.complete?, text
    end
  end

  # What the runner does with each line: a record gives its game at once;
  # the header, the trailer, and a malformed line give nothing.
  def test_each_line_gives_its_record_or_nothing
    stream = ArenaResult::MixedStream.new(%w[g1 g2])
    assert_nil stream.add(HEADER)
    id, result = stream.add(played(id: 'g2'))
    assert_equal ['g2', :black], [id, result.winner]
    assert_nil stream.add('garbage')
    id, result = stream.add(failed(id: 'g1'))
    assert_equal 'g1', id
    assert result.failed?
    assert_nil stream.add('done 2')
    refute stream.complete?
    assert_equal 2, stream.trailer
    assert_equal %w[g1], stream.failures.keys
  end

  def test_the_legacy_parser_does_not_take_the_header
    refute ArenaResult.chunk(output(played), ['g1']).complete?
  end

  def test_missing_trailer
    c = chunk(output(played(id: 'g1'), done: nil), %w[g1 g2])
    refute c.complete?
    assert_nil c.trailer
    assert_equal %w[g2], c.missing
  end

  def test_trailer_count_must_match_the_schedule
    c = chunk(output(played, done: 2))
    refute c.complete?
    assert_equal 2, c.trailer
  end

  def test_a_malformed_trailer_is_no_trailer
    ['done', 'done two', 'done 1 ', 'Done 1'].each do |trailer|
      c = chunk("#{HEADER}\n#{played}\n#{trailer}\n")
      refute c.complete?, trailer
      assert_nil c.trailer, trailer
    end
  end

  def test_accepts_a_trailer_without_a_newline
    assert chunk("#{HEADER}\n#{played}\ndone 1").complete?
  end

  def test_output_after_the_trailer_makes_it_incomplete
    c = chunk("#{HEADER}\n#{played}\ndone 1\n#{played(id: 'g2')}\n", %w[g1 g2])
    refute c.complete?
    assert_nil c.trailer
    assert_equal :black, c.results.fetch('g1').winner
    assert_equal :black, c.results.fetch('g2').winner
  end

  # The first record was taken when it came; a second cannot say which is
  # true, and the arena never writes one.
  def test_a_second_record_for_a_game_is_broken
    assert_broken(output(played(result: 'B+1.5'), played(result: 'W+1.5')), ['g1'], 'wrote a second record for g1')
    assert_broken(output(failed, failed), ['g1'], 'wrote a second record for g1')
  end

  def test_a_record_for_a_game_not_in_the_manifest_is_broken
    assert_broken(output(played(id: 'g1'), failed(id: 'zz')), ['g1'],
                  'wrote a record for zz, which is not in its manifest')
  end

  def test_a_trailer_that_misses_a_game_is_incomplete
    c = chunk(output(played(id: 'g1'), done: 2), %w[g1 g2])
    refute c.complete?
    assert_equal %w[g2], c.missing
  end

  def test_results_and_failures_follow_schedule_order
    c = chunk(output(failed(id: 'b'), played(id: 'c'), failed(id: 'a')), %w[a b c])
    assert_equal %w[a b c], c.results.keys
    assert_equal %w[a b], c.failures.keys
  end

  def test_empty_output
    c = chunk('', %w[g1 g2])
    refute c.header?
    refute c.complete?
    assert_nil c.trailer
    assert_equal %w[g1 g2], c.missing
  end

  def test_only_the_header
    c = chunk("#{HEADER}\n", %w[g1])
    assert c.header?
    refute c.complete?
    assert_equal %w[g1], c.missing
  end

  def test_empty_schedule
    assert chunk("#{HEADER}\ndone 0\n", []).complete?
    refute chunk("done 0\n", []).complete?
  end
end
