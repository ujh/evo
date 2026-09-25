require 'fileutils'
require 'optparse'
require_relative 'experiment_database'
require_relative 'seeds'

class SetupExperiment
  DATABASE = 'experiment.sqlite3'.freeze

  # The prompts were cut short; nothing was saved. Its own class, so the
  # runner can report this without catching errors from the run itself.
  class PromptAborted < StandardError; end

  # A setting's type: a whole number or a number, and its allowed range.
  # Parsing is strict, so a typo is refused instead of being read as its
  # numeric prefix or as 0.
  Type = Data.define(:kind, :min, :max) do
    def parse(key, text)
      value = if kind == :integer
                Integer(text.to_s, 10, exception: false)
              else
                Float(text.to_s, exception: false)
              end
      return value if value && value >= min && (max.nil? || value <= max)

      raise ArgumentError, "#{key} must be #{description}, got #{text}"
    end

    def description
      name = kind == :integer ? 'a whole number' : 'a number'
      max ? "#{name} from #{min} to #{max}" : "#{name} of at least #{min}"
    end
  end

  def self.integer(min, max = nil) = Type.new(:integer, min, max)
  def self.number(min, max) = Type.new(:number, min, max)

  # Every setting, with its prompt, its default, and its type. A nil default
  # means required; a Proc is called for a fresh default. The database keeps
  # the settings as strings, and loading parses them again. Board sizes stop
  # at 19, the largest the GNU Go referee plays.
  SETTINGS = {
    'board_size' => ['Board size', nil, integer(2, 19)],
    'population_size' => ['Population size', nil, integer(1)],
    'hidden_layers' => ['Number of hidden layers', nil, integer(0)],
    'layer_size' => ['Number of neurons per layer', nil, integer(1)],
    'cross_over_rate' => ['Cross over rate', nil, number(0, 1)],
    'game_length' => ['Time per player per game, in minutes', nil, integer(1)],
    'max_moves' => ['Max moves', nil, integer(1)],
    'tournament_rounds' => ['Rounds (tournament)', nil, integer(1)],
    'tournament_size' => ['Tournament size for parent selection', '3', integer(1)],
    'keep_every' => ['Keep the SGFs and networks of every Nth generation (0 for never)', '10', integer(0)],
    'seed' => ['Seed', -> { Seeds.new_experiment_seed.to_s }, integer(0, (2**63) - 1)]
  }.freeze

  EXECUTABLES = %w[engine/evo initial-population/initial-population evolve/evolve].freeze

  # Opens the experiment's database and yields its settings and the database.
  def self.call(experiment_dir)
    puts "Setting up ... ✔"
    FileUtils.mkdir_p(experiment_dir)
    database = ExperimentDatabase.new(File.expand_path(DATABASE, experiment_dir))
    # The settings come first, so aborting their prompts leaves nothing.
    settings = settings(database)
    install_executables(experiment_dir, database)
    Dir.chdir(experiment_dir) { yield settings, database }
  ensure
    database&.close
  end

  # Creates an experiment from command-line options, so it can be started
  # without the prompts (`mise run new-experiment NAME --board-size 9 ...`).
  def self.create(experiment_dir, arguments)
    settings = settings_from_arguments(arguments)
    FileUtils.mkdir_p(experiment_dir)
    database = ExperimentDatabase.new(File.join(experiment_dir, DATABASE))
    raise ArgumentError, "#{experiment_dir} already has settings" unless database.settings.empty?

    database.save_settings(settings)
    settings
  ensure
    database&.close
  end

  # Parses settings read as strings, from the database or the options.
  def self.parse(strings)
    SETTINGS.to_h do |key, (_, _, type)|
      raise ArgumentError, "#{key} is missing" unless strings.key?(key)

      [key, type.parse(key, strings[key])]
    end
  end

  # One --option per setting (board_size becomes --board-size), filling
  # `given` as it parses.
  def self.option_parser(given)
    OptionParser.new do |parser|
      parser.banner = 'Usage: mise run new-experiment NAME [options]'
      # Without this, OptionParser takes --board for --board-size.
      parser.require_exact = true
      SETTINGS.each do |key, (prompt, default, type)|
        note = if default.nil? then 'required'
               elsif default.respond_to?(:call) then 'default random'
               else "default #{default}"
               end
        note = "#{type.description}, #{note}"
        parser.on("--#{key.tr('_', '-')} VALUE", "#{prompt} (#{note})") { |value| given[key] = value }
      end
    end
  end

  def self.settings_from_arguments(arguments)
    given = {}
    rest = option_parser(given).parse(arguments)
    raise ArgumentError, "unexpected arguments: #{rest.join(' ')}" if rest.any?

    missing = SETTINGS.select { |key, (_, default)| default.nil? && !given.key?(key) }.keys
    raise ArgumentError, "missing options: #{missing.map { |key| "--#{key.tr('_', '-')}" }.join(', ')}" if missing.any?

    parse(SETTINGS.to_h { |key, (_, default)| [key, given.fetch(key) { default_for(default) }] })
  rescue OptionParser::ParseError => e
    raise ArgumentError, e.message
  end

  def self.default_for(default)
    default.respond_to?(:call) ? default.call : default
  end

  # Copies the executables into a new experiment, so a later rebuild cannot
  # change it, and records where they came from. The provenance is saved
  # after the copies, so a crash in between copies them again next time.
  # Once it is saved the experiment keeps its executables, and a missing
  # one stops the run rather than being replaced by a different build.
  # Runs in the checkout, like the rest of the runner.
  def self.install_executables(experiment_dir, database)
    targets = EXECUTABLES.map { |path| File.join(experiment_dir, File.basename(path)) }
    unless database.provenance.empty?
      missing = targets.reject { |target| File.exist?(target) }
      raise "#{missing.join(', ')} missing; this experiment cannot run with other executables" if missing.any?

      return
    end

    provenance = current_provenance
    EXECUTABLES.zip(targets) { |source, target| FileUtils.cp(source, target, preserve: true) }
    database.save_provenance(provenance)
  end

  def self.current_provenance
    revision = git('rev-parse', 'HEAD')&.strip
    changes = git('status', '--porcelain', '--untracked-files=no')
    tools = '.local/evo-tools/current'
    {
      'code_revision' => revision.to_s.empty? ? 'unknown' : revision,
      'uncommitted_changes' => changes.nil? ? 'unknown' : (!changes.empty?).to_s,
      'external_tools' => File.exist?(tools) ? File.basename(File.realpath(tools)) : 'none'
    }
  end

  # git's output, or nil when git fails or this is no checkout.
  def self.git(*arguments)
    output = IO.popen(['git', *arguments], err: File::NULL, &:read)
    $?.success? ? output : nil
  rescue SystemCallError
    nil
  end

  # The settings live in the database; a new experiment prompts for them.
  def self.settings(database)
    stored = database.settings
    return parse(stored) unless stored.empty?

    settings = prompt_for_settings
    database.save_settings(settings)
    settings
  end

  # Raises before anything is saved if input ends or a required setting is
  # left empty; saving empty settings would leave an experiment that looks
  # configured but plays zero rounds.
  def self.prompt_for_settings
    SETTINGS.to_h { |key, (prompt, default, type)| [key, prompt_for(key, prompt, default, type)] }
  end

  # Asks until the answer parses.
  def self.prompt_for(key, prompt, default, type)
    label = default.nil? ? prompt : "#{prompt} (default #{default.respond_to?(:call) ? 'random' : default})"
    loop do
      print "#{label}: "
      line = $stdin.gets
      raise PromptAborted, "input ended before #{key} was set" if line.nil?

      answer = line.chomp
      raise PromptAborted, "#{key} is required" if answer.empty? && default.nil?

      begin
        return type.parse(key, answer.empty? ? default_for(default) : answer)
      rescue ArgumentError => e
        puts e.message
      end
    end
  end
end
