# What built an experiment: the git revision of the code whose executables
# were copied into it, whether that checkout had uncommitted changes, and
# the installed external tools release. Written once, when the executables
# are copied.
Sequel.migration do
  change do
    create_table(:provenance) do
      String :key, primary_key: true
      String :value, null: false
    end
  end
end
