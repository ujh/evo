require 'minitest/autorun'
require_relative '../ruby/progress_line'

class ProgressLineUnitTest < Minitest::Test
  class Line
    include ProgressLine
    public :show, :end_line
  end

  LONG = "Deleting generation 12's networks from a directory with a long name ...".ljust(90, '.')

  def test_a_short_status_covers_a_longer_one_it_overwrites
    out, = capture_io do
      line = Line.new
      line.show(LONG)
      line.show('Pairing ...')
    end
    _, before, after = out.split("\r")
    assert_equal LONG, before
    assert_equal 'Pairing ...'.ljust(LONG.length), after
  end

  # A status that starts a new line has nothing to cover, so it is padded
  # only to the usual width, however long the last line was.
  def test_a_status_after_an_ended_line_pads_only_to_the_usual_width
    out, = capture_io do
      line = Line.new
      line.end_line(LONG)
      line.show('Pairing ...')
    end
    assert_equal "\r#{LONG}\n\r#{'Pairing ...'.ljust(ProgressLine::WIDTH)}", out
  end
end
