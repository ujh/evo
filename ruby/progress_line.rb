# The runner's progress line, shared by RunGeneration and CheckpointBenchmark:
# each status overwrites the one before on the same line. Each step that can
# take a while shows once as it begins, so the line never sits on a step
# that is over, and a log (not a terminal) gets one update a step, with
# carriage returns between them.
module ProgressLine
  # A status is padded to this width, and to the width of the status it
  # overwrites, so none of that one remains.
  WIDTH = 70

  private

  # Shows `text` on the progress line in place of what it showed.
  def show(text)
    print "\r#{text.ljust([WIDTH, @shown.to_i].max)}"
    @shown = text.length
  end

  # Shows `text` and ends the line, so the next status starts a new one.
  def end_line(text)
    show(text)
    puts
    @shown = nil
  end
end
