# The networks themselves, which used to be .ann files in per-generation
# directories. The runner keeps a generation's networks while the next one
# needs them as parents, and afterwards only for every keep_every-th
# generation.
Sequel.migration do
  change do
    create_table(:networks) do
      Integer :generation, null: false
      String :name, null: false
      File :weights, null: false # the .ann file's bytes
      primary_key %i[generation name]
    end
  end
end
