require 'fileutils'
require 'optparse'
require_relative 'experiment_database'
require_relative 'feature_groups'
require_relative 'seeds'
require_relative 'run_generation'

class SetupExperiment
  DATABASE = 'experiment.sqlite3'.freeze

  # The prompts were cut short; nothing was saved. Its own class, so the
  # runner can report this without catching errors from the run itself.
  class PromptAborted < StandardError; end

  # A setting's type: a whole number, an even whole number, a number, or a
  # multiple of 0.5, and its allowed range. Parsing is strict, so a typo is
  # refused instead of being read as its numeric prefix or as 0.
  Type = Data.define(:kind, :min, :max) do
    def parse(key, text)
      value = if %i[number half].include?(kind)
                Float(text.to_s, exception: false)
              else
                Integer(text.to_s, 10, exception: false)
              end
      return value if value && value >= min && (max.nil? || value <= max) && fits_kind?(value)

      raise ArgumentError, "#{key} must be #{description}, got #{text}"
    end

    def fits_kind?(value)
      case kind
      when :even then value.even?
      when :half then (value * 2) == (value * 2).round
      else true
      end
    end

    def description
      name = { integer: 'a whole number', even: 'an even whole number', number: 'a number',
               half: 'a multiple of 0.5' }.fetch(kind)
      max ? "#{name} from #{min} to #{max}" : "#{name} of at least #{min}"
    end
  end

  # The feature groups the networks see: `none`, `all`, or groups
  # comma-separated in any order, each once. It parses to the feature set as
  # the genes line writes it (`none`, or the groups in their fixed order),
  # which is also what the database stores.
  FeatureSet = Data.define do
    def parse(key, text)
      FeatureGroups.normalize(text.to_s) or raise ArgumentError, "#{key} must be #{description}, got #{text}"
    end

    def description
      "none, all, or a comma-separated list of #{FeatureGroups::GROUPS.keys.join(', ')}"
    end
  end

  def self.integer(min, max = nil) = Type.new(:integer, min, max)
  def self.even(min) = Type.new(:even, min, nil)
  def self.number(min, max) = Type.new(:number, min, max)
  def self.half(min, max) = Type.new(:half, min, max)

  # A default computed from the settings before it when the experiment is
  # created, and stored like a given value, so a later change of `compute`
  # never changes an experiment that exists. `description` says where it
  # comes from, in the help.
  Derived = Data.define(:description, :compute) do
    def value_for(settings) = compute.call(settings)
  end

  # Every setting, with its prompt, its default, and its type. A nil default
  # means required; a Proc is called for a fresh default, and a Derived is
  # computed from the settings before it. The database keeps the settings
  # as strings, and loading parses them again. Board sizes stop at 19, the
  # largest the GNU Go referee plays. The initial_* settings are the genes
  # every generation-0 network starts with, and their ranges are the clamps
  # in lib/ann.h; evolution changes them from there, at the pace meta_rate
  # (the tau of self-adaptive mutation) sets. initial_feature_noise is no
  # gene but the spread of generation 0's feature weights.
  SETTINGS = {
    'board_size' => ['Board size', nil, integer(2, 19)],
    'population_size' => ['Population size', nil, integer(1)],
    'hidden_layers' => ['Hidden layers of generation 0', nil, integer(0)],
    'layer_size' => ['Neurons per hidden layer of generation 0', nil, integer(1)],
    # The bounds on the shape structural mutation may give a network; the
    # generation-0 shape must be within them.
    'max_hidden_layers' => ['Most hidden layers a network may evolve', '4', integer(0)],
    'max_layer_size' => ['Most neurons per hidden layer a network may evolve', '200', integer(1)],
    # Every network of the experiment sees these groups' features as
    # inputs and has their move features' weights; none gives networks of
    # the stones alone. Before initial_weight_changes, which counts them.
    'features' => ['Feature groups the networks see', 'all', FeatureSet.new],
    'cross_over_rate' => ['Cross over rate', nil, number(0, 1)],
    'game_length' => ['Time per player per game, in minutes', nil, integer(1)],
    'max_moves' => ['Max moves', nil, integer(1)],
    'tournament_rounds' => ['Rounds (tournament)', nil, integer(1)],
    'tournament_size' => ['Tournament size for parent selection', '3', integer(1)],
    'keep_every' => ['Keep the SGFs and networks of every Nth generation (0 for never)', '10', integer(0)],
    'seed' => ['Seed', -> { Seeds.new_experiment_seed.to_s }, integer(0, (2**63) - 1)],
    # Half of a benchmark's games are played with each color.
    'benchmark_games' => ['Benchmark games per opponent', '20', even(2)],
    'benchmark_opening_moves' => ['Stones in each benchmark opening (0 for none)', '4', integer(0)],
    # Given to both players and the referee of every game. A multiple of
    # 0.5, so an area-scored margin is never zero unless the game is a
    # draw, and never prints as W+0.0.
    'komi' => ['Komi', '6.5', half(-50, 50)],
    'meta_rate' => ['Meta rate of self-adaptive mutation', '0.2', number(0, 10)],
    'initial_copy_chance' => ['Chance a child is a copy (initial gene)', '0.01', number(0.0001, 0.1)],
    # The old hard-coded load: 0.0004 changes per weight, at least 1. The count, not
    # the share, is the gene, so growing a network does not raise its load.
    'initial_weight_changes' => [
      'Weights changed per mutated child (initial gene)',
      Derived.new('from the generation-0 shape', ->(settings) { default_weight_changes(settings).to_s }),
      number(1, 1_000_000_000)
    ],
    'initial_weight_step' => ['Largest change of a mutated weight (initial gene)', '0.5', number(0.0001, 10)],
    'initial_activation_rate' => ['Chance a mutation switches each activation (initial gene)', '0.02',
                                  number(0.0001, 0.5)],
    'initial_structure_rate' => ['Chance of a structural mutation (initial gene)', '0.02', number(0.0001, 0.5)],
    # Each generation-0 feature weight is its starting value times (1 + u),
    # u uniform within this, so no weight changes sign.
    'initial_feature_noise' => ['Relative noise on the starting feature weights', '0.3', number(0, 1)],
    'initial_feature_step' => ['Largest change of a mutated feature weight (initial gene)', '0.01', number(0.0001, 1)]
  }.freeze

  # The weights of a network for the board with the given hidden layers and
  # feature set, feature inputs included (FeatureGroups.total_weights).
  def self.total_weights(board_size, layers, width, features)
    FeatureGroups.total_weights(board_size, layers, width, features)
  end

  def self.generation_0_weights(settings)
    total_weights(*settings.values_at('board_size', 'hidden_layers', 'layer_size', 'features'))
  end

  def self.default_weight_changes(settings)
    [1.0, 0.0004 * generation_0_weights(settings)].max
  end

  EXECUTABLES = %w[engine/evo engine/arena initial-population/initial-population evolve/evolve].freeze

  # What a new experiment plays against, what benchmarks it, and how it
  # scores. They are stored with the experiment, and the runner reads them
  # from there, so changing them here only changes experiments created
  # afterwards.
  # Early networks are far too weak for GNU Go, at any level, and its games
  # set most of a generation's wall time, so it stays out of the tournament
  # until networks beat these (see the opponent ladder in PROJECT_NOTES.md).
  # GNU Go still referees the games with a bot; games between two networks
  # are scored by the arena. scripts/smoke-external-tools.sh plays each
  # opponent and each benchmark bot; add new ones there.
  DEFAULT_OPPONENTS = [
    { name: 'Brown', command: 'brown', copies: 5 },
    { name: 'AmiGo', command: 'amigogtp', copies: 10 }
  ].freeze
  # The fixed panel the top network of every checkpoint generation plays, so
  # checkpoints stay comparable however the tournament's opponents change.
  # The two network kinds have no command: the runner picks the network
  # from the experiment's own generations.
  DEFAULT_BENCHMARK = [
    { name: 'Brown', kind: 'bot', command: 'brown' },
    { name: 'AmiGo', kind: 'bot', command: 'amigogtp' },
    { name: 'GnuGoLevel0', kind: 'bot', command: 'gnugo --level 0 --mode gtp' },
    { name: 'Gen0Champion', kind: 'initial_champion', command: nil },
    { name: 'PreviousCheckpoint', kind: 'previous_checkpoint', command: nil }
  ].freeze
  DEFAULT_SCORING = { 'rules' => RunGeneration::SCORING_RULES, 'win' => 1, 'draw' => 0, 'bye' => 0 }.freeze

  # Opens the experiment's database and yields its settings and the database.
  def self.call(experiment_dir)
    puts "Setting up ... ✔"
    FileUtils.mkdir_p(experiment_dir)
    database = ExperimentDatabase.new(File.expand_path(DATABASE, experiment_dir))
    # The settings come first, so aborting their prompts leaves nothing.
    settings = settings(database)
    check_scoring(database)
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

    save_new_experiment(database, settings)
    settings
  ensure
    database&.close
  end

  # Settings, opponents, benchmark panel, and scoring together or not at
  # all, so no experiment has settings it cannot run with.
  def self.save_new_experiment(database, settings)
    database.transaction do
      database.save_settings(settings)
      save_rules(database)
    end
  end

  def self.save_rules(database)
    database.save_opponents(DEFAULT_OPPONENTS)
    database.save_benchmark_opponents(DEFAULT_BENCHMARK)
    database.save_scoring(DEFAULT_SCORING)
  end

  # The scoring logic in the code must be the one the experiment began with.
  def self.check_scoring(database)
    rules = database.scoring['rules']
    return if rules == RunGeneration::SCORING_RULES

    raise "this experiment is scored by rules #{rules.inspect}, but the code scores by #{RunGeneration::SCORING_RULES.inspect}"
  end

  # Parses settings read as strings, from the database or the options.
  def self.parse(strings)
    SETTINGS.each_key.with_object({}) do |key, settings|
      raise ArgumentError, "#{key} is missing" unless strings.key?(key)

      settings[key] = parse_setting(key, strings[key], settings)
    end
  end

  # Parses one setting, checked against the settings before it.
  def self.parse_setting(key, text, settings)
    value = SETTINGS.fetch(key)[2].parse(key, text)
    case key
    when 'max_hidden_layers' then check_bound(key, value, 'hidden_layers', settings)
    # Without hidden layers the width is not used until a layer is added,
    # and that layer is clamped to max_layer_size.
    when 'max_layer_size' then check_bound(key, value, 'layer_size', settings) if settings['hidden_layers'].positive?
    when 'initial_weight_changes' then check_weight_changes(value, text, settings)
    end
    value
  end

  # A bound must admit the generation-0 shape.
  def self.check_bound(key, value, initial, settings)
    return if value >= settings.fetch(initial)

    raise ArgumentError, "#{key} must be at least #{initial} (#{settings.fetch(initial)}), got #{value}"
  end

  def self.check_weight_changes(value, text, settings)
    total = generation_0_weights(settings)
    return if value <= total

    raise ArgumentError, "initial_weight_changes must be at most #{total}, the weights of a generation-0 network, got #{text}"
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
               elsif default.is_a?(Derived) then "default #{default.description}"
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

    SETTINGS.each_with_object({}) do |(key, (_, default)), settings|
      settings[key] = parse_setting(key, given.fetch(key) { default_for(default, settings) }, settings)
    end
  rescue OptionParser::ParseError => e
    raise ArgumentError, e.message
  end

  # The text of a default; `settings` are those parsed so far.
  def self.default_for(default, settings)
    return default.value_for(settings) if default.is_a?(Derived)

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
    save_new_experiment(database, settings)
    settings
  end

  # Raises before anything is saved if input ends or a required setting is
  # left empty; saving empty settings would leave an experiment that looks
  # configured but plays zero rounds.
  def self.prompt_for_settings
    SETTINGS.each_with_object({}) do |(key, (prompt, default)), settings|
      settings[key] = prompt_for(key, prompt, default, settings)
    end
  end

  # Asks until the answer parses. `settings` are those answered so far.
  def self.prompt_for(key, prompt, default, settings)
    shown = if default.is_a?(Derived) then default.value_for(settings)
            elsif default.respond_to?(:call) then 'random'
            else default
            end
    label = default.nil? ? prompt : "#{prompt} (default #{shown})"
    loop do
      print "#{label}: "
      line = $stdin.gets
      raise PromptAborted, "input ended before #{key} was set" if line.nil?

      answer = line.chomp
      raise PromptAborted, "#{key} is required" if answer.empty? && default.nil?

      begin
        return parse_setting(key, answer.empty? ? default_for(default, settings) : answer, settings)
      rescue ArgumentError => e
        puts e.message
      end
    end
  end
end
