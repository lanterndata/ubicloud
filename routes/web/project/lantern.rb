# frozen_string_literal: true

class CloverWeb
  hash_branch(:project_prefix, "lantern") do |r|
    @serializer = Serializers::Web::Lantern

    timeline_servers = @project.lantern_resources_dataset.all
    @timelines = [["", ""]] + timeline_servers.map { |server| [server.id, server.name] }

    r.get true do
      @lantern_databases = serialize(@project.lantern_resources_dataset.authorized(@current_user.id, "Postgres:view").eager(:strand).all)

      view "lantern/index"
    end

    r.post true do
      Authorization.authorize(@current_user.id, "Postgres:create", @project.id)
      parsed_size = Validation.validate_lantern_size(r.params["size"])
      parent_id = r.params["parent_id"].empty? ? nil : r.params["parent_id"]
      restore_target = r.params["restore_target"].empty? ? nil : Time.new("#{r.params["restore_target"]}:00 UTC")

      st = Prog::Lantern::LanternResourceNexus.assemble(
        project_id: @project.id,
        location: r.params["location"],
        name: r.params["name"],
        label: r.params["label"],
        org_id: r.params["org_id"],
        target_vm_size: parsed_size.vm_size,
        target_storage_size_gib: parsed_size.storage_size_gib,
        lantern_version: r.params["lantern_version"],
        extras_version: r.params["extras_version"],
        minor_version: r.params["minor_version"],
        domain: r.params["domain"].empty? ? nil : r.params["domain"],
        db_name: r.params["db_name"],
        db_user: r.params["db_user"],
        parent_id: parent_id,
        restore_target: restore_target
      )

      flash["notice"] = "'#{r.params["name"]}' will be ready in a few minutes"

      r.redirect "#{@project.path}#{LanternResource[st.id].path}"
    end

    r.on "create" do
      r.get true do
        Authorization.authorize(@current_user.id, "Postgres:create", @project.id)

        @prices = fetch_location_based_prices("PostgresCores", "PostgresStorage")
        @has_valid_payment_method = @project.has_valid_payment_method?

        view "lantern/create"
      end
    end
  end
end
