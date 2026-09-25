require 'fileutils'
require_relative 'seeds'

# Seeded random openings for the benchmark games, played through twogtp's
# -openings. A stone never touches another one orthogonally, so no opening
# captures a stone or plays a suicide, whatever the board size.
module Openings
  COLORS = %i[black white].freeze

  # Up to count moves as [color, row, column], colors alternating from black,
  # rows and columns 0-based from the top-left. Fewer when no point is left.
  def self.moves(seed, index, board_size, count)
    rng = Random.new(Seeds.derive(seed, 'benchmark-opening', index))
    free = (0...board_size).to_a.product((0...board_size).to_a)
    moves = []
    while moves.size < count && !free.empty?
      row, column = free.delete_at(rng.rand(free.size))
      free -= [[row - 1, column], [row + 1, column], [row, column - 1], [row, column + 1]]
      moves << [COLORS[moves.size % 2], row, column]
    end
    moves
  end

  # SGF coordinates are the column letter, then the row letter, both from 'a'
  # at the top-left; unlike GTP, SGF does not skip 'i'.
  def self.sgf(board_size, moves)
    nodes = moves.map do |color, row, column|
      ";#{color == :black ? 'B' : 'W'}[#{(97 + column).chr}#{(97 + row).chr}]"
    end
    "(;GM[1]FF[4]SZ[#{board_size}]#{nodes.join})"
  end

  # twogtp's -openings takes a directory and uses its first file for the
  # first game, which is the only game of a twogtp run.
  def self.write(directory, board_size, moves)
    FileUtils.mkdir_p(directory)
    File.write(File.join(directory, 'opening.sgf'), sgf(board_size, moves))
    directory
  end
end
