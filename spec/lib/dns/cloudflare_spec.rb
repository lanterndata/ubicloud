# frozen_string_literal: true

RSpec.describe Dns::Cloudflare do
  describe "#initialize" do
    it "fails to construct class" do
      expect(Config).to receive(:cf_token).and_return(nil)
      expect(Config).to receive(:cf_zone_id).and_return(nil)

      expect {
        described_class.new
      }.to raise_error "Please set CF_TOKEN and CF_ZONE_ID env variables"
    end

    it "success to construct class" do
      expect(Config).to receive(:cf_token).and_return("test")
      expect(Config).to receive(:cf_zone_id).and_return("test")

      expect {
        described_class.new
      }.not_to raise_error
    end
  end

  describe "wtih_instance" do
    before do
      expect(Config).to receive(:cf_token).and_return("test")
      expect(Config).to receive(:cf_zone_id).and_return("test")
    end

    describe "#get_dns_record" do
      it "returns nil" do
        cf = described_class.new
        stub_request(:get, "https://api.cloudflare.com/client/v4/zones/test/dns_records?name=test")
          .to_return(status: 200, body: JSON.dump({result: []}), headers: {})
        expect(cf.get_dns_record("test")).to be_nil
      end

      it "returns data" do
        cf = described_class.new
        stub_request(:get, "https://api.cloudflare.com/client/v4/zones/test/dns_records?name=test")
          .to_return(status: 200, body: JSON.dump({result: [{name: "test"}]}), headers: {})
        expect(cf.get_dns_record("test")["name"]).to eq("test")
      end
    end

    describe "#insert_dns_record" do
      it "successeses" do
        cf = described_class.new
        stub_request(:post, "https://api.cloudflare.com/client/v4/zones/test/dns_records")
          .with(
            body: "{\"content\":\"1.1.1.1\",\"name\":\"test\",\"proxied\":false,\"type\":\"A\",\"comment\":\"dns record for lantern cloud db\",\"ttl\":60}",
            headers: {
              "Authorization" => "Bearer test",
              "Content-Type" => "application/json",
              "Host" => "api.cloudflare.com:443"
            }
          )
          .to_return(status: 200, body: "", headers: {})
        expect {
          cf.insert_dns_record("test", "1.1.1.1")
        }.not_to raise_error
      end
    end

    describe "#update_dns_record" do
      it "successes" do
        cf = described_class.new
        stub_request(:patch, "https://api.cloudflare.com/client/v4/zones/test/dns_records/test-id")
          .with(
            body: "{\"content\":\"1.1.1.1\",\"name\":\"test\",\"proxied\":false,\"type\":\"A\",\"comment\":\"dns record for lantern cloud db\",\"ttl\":60}",
            headers: {
              "Authorization" => "Bearer test",
              "Content-Type" => "application/json",
              "Host" => "api.cloudflare.com:443"
            }
          )
          .to_return(status: 200, body: "", headers: {})
        expect {
          cf.update_dns_record("test-id", "test", "1.1.1.1")
        }.not_to raise_error
      end
    end

    describe "#delete_dns_record" do
      it "returns nil" do
        cf = described_class.new
        stub_request(:get, "https://api.cloudflare.com/client/v4/zones/test/dns_records?name=test")
          .to_return(status: 200, body: JSON.dump({result: []}), headers: {})
        expect(cf.delete_dns_record("test")).to be_nil
      end

      it "deletes the dns record" do
        cf = described_class.new
        stub_request(:get, "https://api.cloudflare.com/client/v4/zones/test/dns_records?name=test")
          .to_return(status: 200, body: JSON.dump({result: [{id: "test-id"}]}), headers: {})
        stub_request(:delete, "https://api.cloudflare.com/client/v4/zones/test/dns_records/test-id")
          .to_return(status: 200, body: "", headers: {})
        expect {
          cf.delete_dns_record("test")
        }.not_to raise_error
      end
    end

    describe "#upsert_dns_record" do
      it "inserts dns record" do
        cf = described_class.new
        stub_request(:get, "https://api.cloudflare.com/client/v4/zones/test/dns_records?name=test")
          .to_return(status: 200, body: JSON.dump({result: []}), headers: {})
        expect(cf).to receive(:insert_dns_record).with("test", "1.1.1.1")
        cf.upsert_dns_record("test", "1.1.1.1")
      end

      it "updates dns record" do
        cf = described_class.new
        stub_request(:get, "https://api.cloudflare.com/client/v4/zones/test/dns_records?name=test")
          .to_return(status: 200, body: JSON.dump({result: [{id: "test-id"}]}), headers: {})
        expect(cf).to receive(:update_dns_record).with("test-id", "test", "1.1.1.1")
        expect {
          cf.upsert_dns_record("test", "1.1.1.1")
        }.not_to raise_error
      end
    end
  end
end
