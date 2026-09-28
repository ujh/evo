# Profiles the runner process for scripts/profile-workload.sh: with
# EVO_PROFILE=PATH set, the runner writes one line to PATH when it exits.
# The line is `profile` followed by key=value fields:
#   utime=S stime=S               CPU seconds of the runner process itself (all its threads)
#   child_utime=S child_stime=S   CPU seconds of the children it waited for (games, arena chunks, evolve)
#   gc_count=N minor_gc_count=N major_gc_count=N gc_time_ms=N
#   total_allocated_objects=N total_freed_objects=N heap_live_slots=N
# The GC fields are Ruby's GC.stat totals over the whole process.
module ProcessProfile
  GC_FIELDS = {
    'gc_count' => :count, 'minor_gc_count' => :minor_gc_count, 'major_gc_count' => :major_gc_count,
    'gc_time_ms' => :time, 'total_allocated_objects' => :total_allocated_objects,
    'total_freed_objects' => :total_freed_objects, 'heap_live_slots' => :heap_live_slots
  }.freeze

  def self.install(path)
    at_exit { File.write(path, "#{line(Process.times, GC.stat)}\n") }
  end

  def self.line(times, gc)
    cpu = { 'utime' => times.utime, 'stime' => times.stime,
            'child_utime' => times.cutime, 'child_stime' => times.cstime }
    fields = cpu.map { |key, seconds| format('%s=%.3f', key, seconds) } +
             GC_FIELDS.map { |key, stat| "#{key}=#{gc.fetch(stat)}" }
    "profile #{fields.join(' ')}"
  end
end
