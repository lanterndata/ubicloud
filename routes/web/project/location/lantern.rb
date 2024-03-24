# frozen_string_literal: true

class CloverWeb
  hash_branch(:project_location_prefix, "lantern") do |r|
    @serializer = Serializers::Web::Postgres

    r.on String do |pg_name|
      puts "PG NAME:::::: %s " % [pg_name]
      puts "PG NAME SQP:::::: %s " % [@project.lantern_servers_dataset.where(location: @location, instance_id: pg_name).sql]
      pg = @project.lantern_servers_dataset.where(location: @location, instance_id: pg_name).first

      unless pg
        response.status = 404
        r.halt
      end
      @pg = serialize(pg, :detailed)

      r.get true do
        Authorization.authorize(@current_user.id, "Postgres:view", pg.id)
        view "postgres/show"
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

      r.post "restart" do
        Authorization.authorize(@current_user.id, "Postgres:edit", pg.id)
        pg.servers.each do |s|
          s.incr_restart
        rescue Sequel::ForeignKeyConstraintViolation
        end
        r.redirect "#{@project.path}#{pg.path}"
      end
    end
  end
end
