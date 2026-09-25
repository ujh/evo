require 'minitest/autorun'
require 'tmpdir'
require_relative '../ruby/openings'

class OpeningsTest < Minitest::Test
  def test_the_same_arguments_give_the_same_moves
    assert_equal Openings.moves(42, 3, 9, 4), Openings.moves(42, 3, 9, 4)
  end

  def test_another_index_or_seed_gives_other_moves
    openings = [Openings.moves(42, 3, 9, 4), Openings.moves(42, 4, 9, 4), Openings.moves(43, 3, 9, 4)]
    assert_equal openings.size, openings.uniq.size
  end

  # Pinned, so a change to the seed derivation or to the draw, which would
  # change every experiment's benchmark openings, fails here.
  def test_a_known_seed_gives_a_known_opening
    assert_equal [[:black, 2, 4], [:white, 5, 6], [:black, 1, 2], [:white, 6, 2]], Openings.moves(42, 3, 9, 4)
  end

  def test_no_moves_for_a_count_of_zero
    assert_equal [], Openings.moves(42, 0, 9, 0)
  end

  def test_colors_alternate_starting_with_black
    colors = Openings.moves(1, 0, 9, 5).map(&:first)
    assert_equal %i[black white black white black], colors
  end

  # No stone touches another orthogonally, so no stone can be captured and
  # no move can be suicide.
  def test_stones_are_on_the_board_distinct_and_never_orthogonally_adjacent
    [5, 9, 19].each do |size|
      50.times do |seed|
        moves = Openings.moves(seed, seed % 7, size, 8)
        assert_equal 8, moves.size
        points = moves.map { |_, row, column| [row, column] }
        assert_equal points.size, points.uniq.size
        points.each do |row, column|
          assert_includes 0...size, row
          assert_includes 0...size, column
        end
        points.combination(2).each do |(r1, c1), (r2, c2)|
          refute_equal 1, (r1 - r2).abs + (c1 - c2).abs, "adjacent stones on #{size}x#{size}: #{points.inspect}"
        end
      end
    end
  end

  def test_stops_early_when_no_point_is_left
    # On 2x2 only two diagonal points can hold stones that do not touch.
    moves = Openings.moves(7, 0, 2, 4)
    assert_equal 2, moves.size
  end

  def test_sgf_for_a_known_move_list
    moves = [[:black, 2, 3], [:white, 6, 5], [:black, 0, 0]]
    assert_equal '(;GM[1]FF[4]SZ[9];B[dc];W[fg];B[aa])', Openings.sgf(9, moves)
  end

  def test_sgf_coordinates_are_column_then_row_without_skipping_i
    assert_equal '(;GM[1]FF[4]SZ[9];B[ia])', Openings.sgf(9, [[:black, 0, 8]])
  end

  def test_write_puts_one_sgf_file_in_a_new_directory
    Dir.mktmpdir do |tmp|
      directory = File.join(tmp, 'openings', '3')
      moves = [[:black, 2, 3]]
      assert_equal directory, Openings.write(directory, 9, moves)
      assert_equal ['opening.sgf'], Dir.children(directory)
      assert_equal Openings.sgf(9, moves), File.read(File.join(directory, 'opening.sgf'))
    end
  end

  def test_gogui_twogtp_plays_the_opening_first
    skip 'gogui-twogtp is not on PATH' unless system('command -v gogui-twogtp > /dev/null 2>&1')
    skip 'brown is not on PATH' unless system('command -v brown > /dev/null 2>&1')

    Dir.mktmpdir do |tmp|
      moves = Openings.moves(42, 0, 9, 4)
      directory = Openings.write(File.join(tmp, 'openings'), 9, moves)
      prefix = File.join(tmp, 'game')
      assert system('gogui-twogtp', '-black', 'brown', '-white', 'brown', '-size', '9', '-auto', '-games', '1',
                    '-sgffile', prefix, '-openings', directory, '-force', '-maxmoves', '20',
                    out: File::NULL, err: File::NULL)
      played = File.read("#{prefix}-0.sgf").scan(/;([BW])\[([a-s]{2})\]/)
      expected = Openings.sgf(9, moves).scan(/;([BW])\[([a-s]{2})\]/)
      assert_equal expected, played.first(expected.size)
      assert_operator played.size, :>, expected.size
    end
  end
end
