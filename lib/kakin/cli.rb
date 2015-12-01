require 'date'
require 'yaml'
require 'json'
require 'net/http'
require 'yao'
require 'thor'

module Kakin
  class CLI <Thor
    default_command :calc

    option :f, type: :string, banner: "<file>", desc: "cost define file(yaml)", required: true
    option :s, type: :string, banner: "<start>", desc: "start time", default: (DateTime.now << 1).strftime("%Y-%m-01")
    option :e, type: :string, banner: "<end>", desc: "end time", default: Time.now.strftime("%Y-%m-01")
    desc 'calc', 'Calculate the cost'
    def calc
      Kakin::Configuration.setup

      cost = YAML.load_file(options[:f])
      start_time = Time.parse(options[:s]).strftime("%FT%T")
      end_time = Time.parse(options[:e]).strftime("%FT%T")

      STDERR.puts "Start: #{start_time}"
      STDERR.puts "End:   #{end_time}"
      url = URI.parse("#{Kakin::Configuration.management_url}/#{Yao::Tenant.get_by_name(Kakin::Configuration.tenant).id}/os-simple-tenant-usage?start=#{start_time}&end=#{end_time}")
      req = Net::HTTP::Get.new(url)
      req["Accept"] = "application/json"
      req["X-Auth-Token"] = Yao::Auth.try_new.token
      res = Net::HTTP.start(url.host, url.port) {|http|
        http.request(req)
      }

      if res.code != "200"
        raise "usage data fatch is failed"
      else
        result = Hash.new
        JSON.load(res.body)["tenant_usages"].each do |usage|
          tenant = Yao::Tenant.get(usage["tenant_id"])

          total_incoming_usage = tenant.servers.inject(0) do |server, t|
            incomings = server.old_samples(counter_name: 'network.incoming.bytes', query: {'q.field': 'timestamp', 'q.op': 'gt', 'q.value': start_time.iso8601}).sort_by(&:timestamp)
            last_incoming_index = incomings.find{|s| s.timestamp > end_time }
            if last_incoming_index
              t + (incomings[last_incoming_index].counter_volume - incomings[0].counter_volume)
            else
              t + (incomings[-1].counter_volume - incomings[0].counter_volume)
            end
          end

          total_outgoing_usage = tenant.servers.inject(0) do |server, t|
            outgoings = server.old_samples(counter_name: 'network.outgoing.bytes', query: {'q.field': 'timestamp', 'q.op': 'gt', 'q.value': start_time.iso8601})
            last_outgoing_index = outgoings.find{|s| s.timestamp > end_time }
            if last_outgoing_index
              t + (outgoings[last_outgoing_index].counter_volume - outgoings[0].counter_volume)
            else
              t + (outgoings[-1].counter_volume - outgoings[0].counter_volume)
            end
          end

          total_vcpus_usage     = usage["total_vcpus_usage"]
          total_memory_mb_usage = usage["total_memory_mb_usage"]
          total_local_gb_usage  = usage["total_local_gb_usage"]

          bill_vcpu   = total_vcpus_usage * cost["vcpu_per_hour"]
          bill_memory = total_memory_mb_usage * cost["memory_mb_per_hour"]
          bill_disk   = total_local_gb_usage * cost["disk_gb_per_hour"]

          result[tenant.name] = {
            'bill_total'            => bill_vcpu + bill_memory + bill_disk,
            'bill_vcpu'             => bill_vcpu,
            'bill_memory'           => bill_memory,
            'bill_disk'             => bill_disk,
            'total_hours'           => usage["total_hours"],
            'total_vcpus_usage'     => total_vcpus_usage,
            'total_memory_mb_usage' => total_memory_mb_usage,
            'total_local_gb_usage'  => total_local_gb_usage,
            'total_incoming_usage'  => total_incoming_usage,
            'total_outgoing_usage'  => total_outgoing_usage,
          }
        end

        puts YAML.dump(result)
      end
    end
  end
end
