# How each child came about beyond its operator, and the genes it carries
# (see the genes line in lib/ann.h). `parent` is the parent evolve picked
# (first or second, in argument order): the one a mutation or copy came
# from, or the one whose weights come first in a crossover. `structure` is
# the structural change of a mutation, `activation_changed` whether a
# mutation switched an activation. Generation 0 has genes but neither
# parent, structure, nor activation_changed. Births recorded before this
# have none of them. The genes are not called genome_*: `genome` is the
# SHA-256 of the .ann file.
Sequel.migration do
  change do
    alter_table(:births) do
      add_column :parent, String
      add_column :structure, String
      add_column :activation_changed, TrueClass
      add_column :layers, Integer
      add_column :width, Integer
      add_column :act_hidden, String
      add_column :act_output, String
      add_column :copy_chance, Float
      add_column :weight_changes, Float
      add_column :weight_step, Float
      add_column :activation_rate, Float
      add_column :structure_rate, Float
    end
  end
end
