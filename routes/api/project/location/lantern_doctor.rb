# frozen_string_literal: true

class CloverApi
  hash_branch(:project_location_lantern_prefix, "doctor") do |r|
    @serializer = Serializers::Api::LanternDoctorQuery

    r.get true do
      result = @pg.doctor.queries.authorized(@current_user.id, "Postgres:view").eager(:semaphores, :strand).paginated_result(
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
  end
end
