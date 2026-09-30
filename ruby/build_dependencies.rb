require 'open3'

# Builds the C programs with `make` in the checkout. SetupExperiment calls
# it on an experiment's first run only, just before it copies them.
class BuildDependencies
  # `make` failed; the message is its stdout and stderr.
  class Failed < StandardError; end

  def self.call
    print "Building C programs ..."
    output, status = Open3.capture2e('make')
    if status.success?
      print " ✔\n"
    else
      print " ❌\n"
      raise Failed, output
    end
  end
end
