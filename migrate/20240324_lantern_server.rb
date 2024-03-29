# frozen_string_literal: true

Sequel.migration do
  up do
    create_enum(:instance_type, %w[writer reader])
    create_table(:lantern_server) do
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_uuid()")
      column :name, :text, collate: '"C"'
      column :project_id, :project, type: :uuid, null: false
      column :org_id, Integer
      column :location, :text, collate: '"C"'
      column :lantern_version, :text, collate: '"C"'
      column :extras_version, :text, collate: '"C"'
      column :minor_version, :text, collate: '"C"'
      column :instance_type, :instance_type, null: false, default: "writer"
      column :db_name, :text, collate: '"C"', null: false, default: "postgres"
      column :db_user, :text, collate: '"C"', null: false, default: "postgres"
      column :db_user_password, :text, collate: '"C"'
      column :repl_user, :text, collate: '"C"', null: false, default: "repl_user"
      column :repl_password, :text, collate: '"C"', null: false
      column :app_env, :text, collate: '"C"', null: false, default: "production"
      column :debug, :bool, null: false, default: false
      column :enable_telemetry, :bool, null: false, default: true
      column :postgres_password, :text, collate: '"C"', null: false
      column :master_host, :text, collate: '"C"'
      column :master_port, Integer
      column :target_vm_size, :text, collate: '"C"', null: false
      column :target_storage_size_gib, :bigint, null: false
      foreign_key :vm_id, :gcp_vm, type: :uuid
      column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")
    end
  end
  down do
    drop_table(:lantern_server)
    drop_enum(:instance_type)
  end
end
