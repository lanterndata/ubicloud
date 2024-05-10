# frozen_string_literal: true

class CloverWeb
  hash_branch(:project_location_lantern_prefix, "doctor") do |r|
    @serializer = Serializers::Api::LanternDoctorQuery
    @lantern_doctor = LanternResource[@pg[:id]].doctor

    r.on "incidents" do
      r.on String do |incident_id|
        incident = LanternDoctorPage[incident_id]

        unless incident
          response.status = 404
          r.halt
        end

        r.post "trigger" do
          incident.trigger
          r.redirect "#{@project.path}/lantern-doctor"
        end

        r.post "ack" do
          incident.ack
          r.redirect "#{@project.path}/lantern-doctor"
        end

        r.post "resolve" do
          incident.resolve
          incident.query.update(condition: "healthy")
          r.redirect "#{@project.path}/lantern-doctor"
        end
      end
    end
  end
end
