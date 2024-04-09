# frozen_string_literal: true

Sequel.migration do
  no_transaction
  up do
    create_enum(:timeline_access, %w[push fetch])
    create_enum(:ha_type, %w[none async sync])
    create_enum(:synchronization_status, %w[catching_up ready])

    create_table(:lantern_resource) do
      column :id, :uuid, primary_key: true, default: nil
      foreign_key :parent_id, :lantern_resource, type: :uuid, null: true
      column :name, :text, collate: '"C"'
      column :project_id, :project, type: :uuid, null: false
      column :org_id, Integer
      column :location, :text, collate: '"C"'
      column :db_name, :text, collate: '"C"', null: false, default: "postgres"
      column :db_user, :text, collate: '"C"', null: false, default: "postgres"
      column :db_user_password, :text, collate: '"C"'
      column :repl_user, :text, collate: '"C"', null: false, default: "repl_user"
      column :repl_password, :text, collate: '"C"', null: false
      column :superuser_password, :text, collate: '"C"', null: false
      column :app_env, :text, collate: '"C"', null: false, default: "production"
      column :ha_type, :ha_type, null: false, default: "none"
      column :debug, :bool, null: false, default: false
      column :enable_telemetry, :bool, null: false, default: true
      column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")
    end

    create_table(:lantern_server) do
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_uuid()")
      column :resource_id, :lantern_resource, type: :uuid, null: false
      column :lantern_version, :text, collate: '"C"'
      column :extras_version, :text, collate: '"C"'
      column :minor_version, :text, collate: '"C"'
      column :timeline_access, :timeline_access, null: false, default: "push"
      column :target_vm_size, :text, collate: '"C"', null: false
      column :target_storage_size_gib, :bigint, null: false
      column :representative_at, :timestamptz, null: true, default: nil
      column :synchronization_status, :synchronization_status, null: false, default: "ready"
      column :domain, :text
      foreign_key :vm_id, :gcp_vm, type: :uuid
      column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")
    end

    alter_table(:lantern_server) do
      add_index :resource_id, unique: true, where: Sequel.~(representative_at: nil), concurrently: true
    end
  end
  down do
    drop_table(:lantern_resource)
    drop_table(:lantern_server)
    drop_enum(:timeline_access)
  end
end
