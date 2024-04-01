RSpec.describe Hosting::GcpApis do
  describe "#initialize" do
    it "should fail" do
      expect(Config).to receive(:gcp_project_id).and_return(nil)
      expect {
        described_class.new
      }.to raise_error "Please set GCP_PROJECT_ID env variable"
    end

    it "should fail auth" do
      expect(Config).to receive(:gcp_project_id).and_return("test-proj-id")
      expect(Google::Auth).to receive(:get_application_default).and_raise "test"
      expect {
       described_class.new
      }.to raise_error "Google Auth failed, try setting 'GOOGLE_APPLICATION_CREDENTIALS' env varialbe"
    end
  end
end
