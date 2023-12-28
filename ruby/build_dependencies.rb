require 'open3'

class BuildDependencies
  def self.call
    print "Building C programs ..."
    stdout, stderr, status = Open3.capture3('make')
    if status.success?
      print " ✔\n"
      return true
    else
      print " ❌\n"
      puts stdout
      return false
    end
  end
end
