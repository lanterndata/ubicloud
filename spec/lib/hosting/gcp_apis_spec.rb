require 'ostruct'

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

  describe "#check_errorsk" do
    it "should throw error from response" do
      expect {
        described_class.check_errors(OpenStruct.new({body: JSON.dump({error: {errors: [{message: "test error"}]}})}))
      }.to raise_error "test error"
    end

    it "should not throw error" do
      described_class.check_errors(OpenStruct.new({body: JSON.dump({error: {errors: []}})}))
    end
  end
end
