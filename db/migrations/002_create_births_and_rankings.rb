# Per-generation records for checking the experiment's assumptions: how each
# network came about, and how each generation ended.
Sequel.migration do
  change do
    # One row per network. Generation 0's networks have operator "initial" and
    # no parents. A count of 0 differing weights means a copy of that parent.
    create_table(:births) do
      Integer :generation, null: false
      String :child, null: false
      String :first_parent
      String :second_parent
      String :operator, null: false
      Integer :differs_from_first
      Integer :differs_from_second
      Bignum :seed, null: false
      String :genome, null: false # SHA-256 of the .ann file
      primary_key %i[generation child]
    end

    create_table(:rankings) do
      Integer :generation, null: false
      Integer :rank, null: false
      String :name, null: false
      Integer :score, null: false
      TrueClass :external, null: false
      primary_key %i[generation name]
    end
  end
end
