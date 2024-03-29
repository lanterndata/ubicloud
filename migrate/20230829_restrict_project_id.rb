# frozen_string_literal: true

Sequel.migration do
  no_transaction

  change do
    alter_table(:project) do
      add_index Sequel.lit("right(id::text, 10)"), unique: true, concurrently: true
    end
  end
end
