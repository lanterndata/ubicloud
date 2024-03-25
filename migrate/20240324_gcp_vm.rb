# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:gcp_vm) do
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_uuid()")
      column :name, :text, collate: '"C"'
      column :unix_user, :text, collate: '"C"'
      column :public_key, :text, collate: '"C"', null: false
      column :boot_image, :text, collate: '"C"'
      column :family, :text, collate: '"C"'
      column :arch, :arch, default: "x64", null: false
      column :location, :text, collate: '"C"'
      column :cores, Integer
      column :storage_size_gib, Integer
      column :domain, :text
      column :has_static_ipv4, :bool, default: false
      column :display_state, :vm_display_state, default: "creating", null: false
      column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")
    end
  end
  down do
    drop_table(:gcp_vm)
  end
end
