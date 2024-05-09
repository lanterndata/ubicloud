# frozen_string_literal: true

class CloverApi
  hash_branch(:project_location_lantern_prefix, "doctor") do |r|
    @serializer = Serializers::Api::LanternDoctorQuery
    @lantern_doctor = LanternResource[@pg[:id]].doctor

    r.get true do
      result = LanternDoctorQuery.where(doctor_id: @lantern_doctor.id).paginated_result(
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

    r.on "incidents" do
      r.on String do |incident_id|
        incident = LanternDoctorPage[incident_id]

        unless incident
          response.status = 404
          r.halt
        end

        r.post "trigger" do
          incident.trigger
          response.status = 204
          r.halt
        end

        r.post "ack" do
          incident.ack
          response.status = 204
          r.halt
        end

        r.post "resolve" do
          incident.resolve
          response.status = 204
          r.halt
        end
      end

      r.get true do
        result = LanternDoctorQuery.where(doctor_id: @lantern_doctor.id, condition: "failed").paginated_result(
          cursor: r.params["cursor"],
          page_size: r.params["page_size"],
          order_column: r.params["order_column"]
        )

        {
          items: serialize(result[:records], :detailed),
          next_cursor: result[:next_cursor],
          count: result[:count]
        }
      end
    end

    r.on String do |query_id|
      query = LanternDoctorQuery[query_id]

      unless query
        response.status = 404
        r.halt
      end

      r.post "run" do
        query.update(last_checked: nil)
        response.status = 204
        r.halt
      end
    end
  end
end
