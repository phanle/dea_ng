require "spec_helper"
require "securerandom"

describe "Running an app", :type => :integration, :requires_warden => true do
  let(:nats) { NatsHelper.new }
  let(:unstaged_url) { "http://localhost:9999/unstaged/sinatra" }
  let(:staged_url) { "http://localhost:9999/staged/sinatra" }
  let(:buildpack_cache_download_uri) { "http://localhost:9999/buildpack_cache" }
  let(:buildpack_cache_upload_uri) { "http://localhost:9999/buildpack_cache" }
  let(:app_id) { SecureRandom.hex(8) }
  let(:original_memory) do
    dea_config["resources"]["memory_mb"] * dea_config["resources"]["memory_overcommit_factor"]
  end
  let(:valid_provided_service) do
    {
      "credentials" => { "user" => "Jerry", "password" => "Jellison" },
      "options" => {},
      "label" => "Unmanaged Service abcdefg",
      "name" => "monacle"
    }
  end

  let(:start_message) do
    {
      "index" => 1,
      "droplet" => app_id,
      "version" => "some-version",
      "name" => "some-app-name",
      "uris" => [],
      "sha1" => sha1_url(staged_url),
      "executableUri" => staged_url,
      "cc_partition" => "foo",
      "limits" => {
        "mem" => 64,
        "disk" => 128,
        "fds" => 32
      },
      "services" => [valid_provided_service]
    }
  end

  let(:staging_message) do
    {
      "app_id" => app_id,
      "properties" => { "buildpack" => fake_buildpack_url("start_command"), },
      "download_uri" => unstaged_url,
      "upload_uri" => staged_url,
      "buildpack_cache_upload_uri" => buildpack_cache_upload_uri,
      "buildpack_cache_download_uri" => buildpack_cache_download_uri,
      "start_message" => start_message
    }
  end

  describe "setting up an invalid application" do
    let(:start_message) do
      {
        "index" => 1,
        "droplet" => app_id,
        "version" => "some-version",
        "name" => "some-app-name",
        "uris" => "invalid-uri",
        "sha1" => sha1_url(staged_url),
        "executableUri" => staged_url,
        "cc_partition" => "foo",
        "limits" => {
          "mem" => 64,
          "disk" => 128,
          "fds" => 32
        },
        "services" => [valid_provided_service]
      }
    end

    it "does not allocate any memory" do
      setup_fake_buildpack("start_command")

      nats.make_blocking_request("staging", staging_message, 2)

      begin
        wait_until do
          nats.request("dea.find.droplet", {
            "droplet" => app_id,
          }, :timeout => 1)
        end

        fail("App was created and should not have been")
      rescue Timeout::Error
        expect(dea_memory).to eql(original_memory)
      end
    end
  end

  describe 'starting a valid application' do
    before do
      setup_fake_buildpack("start_command")

      nats.make_blocking_request("staging", staging_message, 2)
    end

    after do
      nats.publish("dea.stop", {"droplet" => app_id})
    end

    describe "starting the app" do
      before { wait_until_instance_started(app_id) }

      it "decreases the dea's available memory" do
        expect(dea_memory).to eql(original_memory - 64)
      end
    end

    describe "stopping the app" do
      it "restores the dea's available memory" do
        wait_until_instance_started(app_id)

        nats.publish("dea.stop", {"droplet" => app_id})
        wait_until_instance_gone(app_id)
        expect(dea_memory).to eql(original_memory)
      end

      it "actually stops the app" do
        id = dea_id
        checked_port = false
        droplet_message = Yajl::Encoder.encode("droplet" => app_id, "states" => ["RUNNING"])
        NATS.start do
          NATS.subscribe("router.register") do |_|
            NATS.request("dea.find.droplet", droplet_message, :timeout => 5) do |response|
              droplet_info = Yajl::Parser.parse(response)
              instance_info = instance_snapshot(droplet_info["instance"])
              # This is a lie. should be hitting VCAP.local_ip (which is eth0). See story #53675073
              ip = instance_info["warden_host_ip"]
              port = instance_info["instance_host_port"]
              expect(is_port_open?(ip, port)).to eq(true)

              NATS.publish("dea.stop", Yajl::Encoder.encode({"droplet" => app_id})) do
                port_open = true
                wait_until(10) do
                  port_open = is_port_open?(ip, port)
                  ! port_open
                end
                expect(port_open).to eq(false)
                checked_port = true
                NATS.stop
              end
            end
          end

          NATS.publish("dea.#{id}.start", Yajl::Encoder.encode(start_message))
        end

        expect(checked_port).to eq(true)
      end
    end
  end
end
