# frozen_string_literal: true

class CloverApi
  hash_branch(:project_prefix, "lantern") do |r|
    @serializer = Serializers::Api::Lantern

    r.get true do
      result = @project.lantern_resources_dataset.authorized(@current_user.id, "Postgres:view").eager(:semaphores, :strand).paginated_result(
        cursor: r.params["cursor"],
        page_size: r.params["page_size"],
        order_column: r.params["order_column"]
      )

      {
        items: serialize(result[:records]),
        next_cursor: result[:next_cursor],
        count: result[:count]
      }
    end

    r.post true do
      Authorization.authorize(@current_user.id, "Postgres:create", @project.id)
      parsed_size = Validation.validate_lantern_size(r.params["size"])
      Validation.validate_name(r.params["name"])
      Validation.validate_org_id(r.params["org_id"])
      restore_target = nil

      if r.params["parent_id"].nil?
        Validation.validate_version(r.params["lantern_version"], "lantern_version")
        Validation.validate_version(r.params["extras_version"], "extras_version")
        Validation.validate_version(r.params["minor_version"], "minor_version")
      else
        restore_target = r.params["restore_target"].nil? ? Time.new : Time.new(r.params["restore_target"])
      end

      domain = r.params["domain"]

      if domain.nil? && r.params["subdomain"]
        domain = "#{r.params["subdomain"]}.#{Config.lantern_top_domain}"
      end

      st = Prog::Lantern::LanternResourceNexus.assemble(
        project_id: @project.id,
        location: r.params["location"],
        name: r.params["name"],
        org_id: r.params["org_id"].to_i,
        target_vm_size: parsed_size.vm_size,
        target_storage_size_gib: r.params["storage_size_gib"] || parsed_size.storage_size_gib,
        lantern_version: r.params["lantern_version"],
        extras_version: r.params["extras_version"],
        minor_version: r.params["minor_version"],
        domain: domain,
        db_name: r.params["db_name"],
        db_user: r.params["db_user"],
        db_user_password: r.params["db_user_password"],
        app_env: r.params["app_env"] || Config.rack_env,
        repl_password: r.params["repl_password"],
        enable_debug: r.params["enable_debug"],
        superuser_password: r.params["postgres_password"],
        parent_id: r.params["parent_id"],
        restore_target: restore_target
      )
      pg = LanternResource[st.id]
      serialize(pg, :detailed)
    end
  end
end
