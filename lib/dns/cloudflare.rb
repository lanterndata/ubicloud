# frozen_string_literal: true

require_relative "../../config"
class Dns::Cloudflare
  def initialize
    @token = Config.cf_token
    @zone_id = Config.cf_zone_id

    if !(@token && @zone_id)
      fail "Please set CF_TOKEN and CF_ZONE_ID env variables"
    end

    @host = {
      :connection_string => "https://api.cloudflare.com",
      :headers => { :'Authorization' => "Bearer #{@token}", :'Content-Type' => 'application/json' }
    }
  end

  def get_dns_record(domain)
    connection = Excon.new(@host[:connection_string], headers: @host[:headers])
    response = connection.get(path: "/client/v4/zones/#{@zone_id}/dns_records", query: { :name => domain }, expects: 200)

    body = JSON.parse(response.body)

    if body["result"].empty?
      return nil
    end

    body["result"][0]
  end

  def insert_dns_record(domain, ip)
    connection = Excon.new(@host[:connection_string], headers: @host[:headers])
    body = {
      :content => ip,
      :name => domain,
      :proxied => false,
      :type => "A",
      :comment => "dns record for lantern cloud db",
      :ttl => 60
    }

    connection.post(path: "/client/v4/zones/#{@zone_id}/dns_records", body: JSON.dump(body), expects: 200)
  end

  def update_dns_record(record_id, domain, ip)
    connection = Excon.new(@host[:connection_string], headers: @host[:headers])
    body = {
      :content => ip,
      :name => domain,
      :proxied => false,
      :type => "A",
      :comment => "dns record for lantern cloud db",
      :ttl => 60
    }

    connection.patch(path: "/client/v4/zones/#{@zone_id}/dns_records/#{record_id}", body: JSON.dump(body), expects: 200)
  end

  def upsert_dns_record(domain, ip)
    record = get_dns_record(domain)

    if record == nil
      return insert_dns_record(domain, ip)
    end

    update_dns_record(record["id"], domain, ip)
  end

  def delete_dns_record(domain)
    connection = Excon.new(@host[:connection_string], headers: @host[:headers])
    record = get_dns_record(domain)
    if record == nil
        return
    end
    connection.delete(path: "/client/v4/zones/#{@zone_id}/dns_records/#{record["id"]}", expects: 200)
  end

end
