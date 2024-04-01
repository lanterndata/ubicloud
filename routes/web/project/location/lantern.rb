# frozen_string_literal: true

class CloverWeb
  hash_branch(:project_location_prefix, "lantern") do |r|
    @serializer = Serializers::Web::Lantern

    r.on String do |pg_name|
      pg = @project.lantern_servers_dataset.where(location: @location).where { {Sequel[:lantern_server][:name] => pg_name} }.first

      unless pg
        response.status = 404
        r.halt
      end
      @pg = serialize(pg, :detailed)

      r.get true do
        Authorization.authorize(@current_user.id, "Postgres:view", pg.id)
        view "lantern/show"
      end

      r.delete true do
        Authorization.authorize(@current_user.id, "Postgres:delete", pg.id)
        pg.incr_destroy
        return {message: "Deleting #{pg.name}"}.to_json
      end

      r.post "reset-user-password" do
        Authorization.authorize(@current_user.id, "Postgres:create", @project.id)
        Authorization.authorize(@current_user.id, "Postgres:view", pg.id)

        Validation.validate_postgres_superuser_password(r.params["original_password"], r.params["repeat_password"])

        pg.update(db_user_password: r.params["original_password"])
        pg.incr_update_user_password

        flash["notice"] = "The superuser password will be updated in a few seconds"
        r.redirect "#{@project.path}#{pg.path}"
      end

      r.post "update-extension" do
        Authorization.authorize(@current_user.id, "Postgres:edit", pg.id)

        pg.incr_update_rhizome

        if r.params["lantern_version"] != pg.lantern_version
          pg.update(lantern_version: r.params["lantern_version"])
          pg.incr_update_lantern_extension
        end

        if r.params["extras_version"] != pg.extras_version
          pg.update(extras_version: r.params["extras_version"])
          pg.incr_update_extras_extension
        end

        r.redirect "#{@project.path}#{pg.path}"
      end

      r.post "update-image" do
        Authorization.authorize(@current_user.id, "Postgres:edit", pg.id)

        pg.update(lantern_version: r.params["img_lantern_version"] || pg.lantern_version, extras_version: r.params["img_extras_version"] || pg.extras_version, minor_version: r.params["img_minor_version"] || pg.minor_version)
        pg.incr_update_rhizome
        pg.incr_update_image
        r.redirect "#{@project.path}#{pg.path}"
      end

      r.post "add-domain" do
        Authorization.authorize(@current_user.id, "Postgres:edit", pg.id)
        DB.transaction do
          GcpVm.dataset.where(id: pg.vm_id).update(domain: r.params["domain"])
          pg.incr_add_domain
        end
        r.redirect "#{@project.path}#{pg.path}"
      end

      r.post "update-rhizome" do
        Authorization.authorize(@current_user.id, "Postgres:edit", pg.id)
        DB.transaction do
          pg.incr_update_rhizome
        end
        r.redirect "#{@project.path}#{pg.path}"
      end

      # r.post "restart" do
      #   Authorization.authorize(@current_user.id, "postgres:edit", pg.id)
      #   pg.gcp_vm.incr_restart
      #   r.redirect "#{@project.path}#{pg.path}"
      # end
    end
  end
end
