# frozen_string_literal: true

Sequel.migration do
  up do
    create_enum(:doctor_page_status, %w[new triggered acknowledged resolved])
    create_table(:lantern_doctor_page) do
      column :id, :uuid, primary_key: true, default: nil
      foreign_key :query_id, :lantern_doctor_query, type: :uuid
      foreign_key :page_id, :page, type: :uuid
      column :status, :doctor_page_status, null: false, default: "new"
      column :db, :text, null: true, default: "postgres"
      column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")
      column :updated_at, :timestamptz, null: false, default: Sequel.lit("now()")
    end
  end

  down do
    drop_table(:lantern_doctor_page)
  end
end
