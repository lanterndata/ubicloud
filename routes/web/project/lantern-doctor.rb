# frozen_string_literal: true

class CloverWeb
  hash_branch(:project_prefix, "lantern-doctor") do |r|
    @serializer = Serializers::Web::LanternDoctorQuery

    r.get true do
      @lantern_incidents = serialize(LanternDoctorQuery.where(condition: "failed").all, :detailed)
      view "lantern-doctor/index"
    end
  end
end
