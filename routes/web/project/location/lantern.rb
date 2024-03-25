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

      r.post "reset-superuser-password" do
        Authorization.authorize(@current_user.id, "Postgres:create", @project.id)
        Authorization.authorize(@current_user.id, "Postgres:view", pg.id)

        unless pg.representative_server.primary?
          flash["error"] = "Superuser password cannot be updated during restore!"
          return redirect_back_with_inputs
        end

        Validation.validate_postgres_superuser_password(r.params["original_password"], r.params["repeat_password"])

        pg.update(postgres_password: r.params["original_password"])
        pg.representative_server.incr_update_superuser_password

        flash["notice"] = "The superuser password will be updated in a few seconds"

        r.redirect "#{@project.path}#{pg.path}"
      end

      r.post "update_extension" do
        Authorization.authorize(@current_user.id, "postgres:edit", pg.id)

        if r.params["lantern_version"]
           pg.update(lantern_version: r.params["lantern_version"])
           pg.incr_update_lantern_extension
        end
        if r.params["extras_version"]
           pg.update(extras_version: r.params["extras_version"])
           pg.incr_update_extras_extension
        end
        r.redirect "#{@project.path}#{pg.path}"
      end

      r.post "update_image" do
        Authorization.authorize(@current_user.id, "postgres:edit", pg.id)

        pg.update(lantern_version: r.params["lantern_version"] || pg.lantern_version, extras_version: r.params["extras_version"] || pg.extras_version, minor_version: r.params["minor_version"] || pg.minor_version)
        pg.incr_update_image
        r.redirect "#{@project.path}#{pg.path}"
      end

      r.post "setup_ssl" do
        Authorization.authorize(@current_user.id, "postgres:edit", pg.id)

        pg.gcp_vm.update(domain: r.params["domin"])
        pg.incr_setup_ssl
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
