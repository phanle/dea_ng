# coding: UTF-8

require "em/warden/client/connection"
require "steno"
require "steno/core_ext"
require "dea/promise"
require "vmstat"
require "dea/container/container"

module Dea
  class Task
    class BaseError < StandardError; end
    class WardenError < BaseError; end
    class NotImplemented < StandardError; end

    BIND_MOUNT_MODE_MAP = {
      "ro" =>  ::Warden::Protocol::CreateRequest::BindMount::Mode::RO,
      "rw" =>  ::Warden::Protocol::CreateRequest::BindMount::Mode::RW,
    }

    attr_reader :config
    attr_reader :logger

    def initialize(config, custom_logger=nil)
      @config = config
      @logger = custom_logger || self.class.logger.tag({})
      @warden_connections = {}
    end

    def start(&blk)
      raise NotImplemented
    end

    def container
      @container ||= Dea::Container.new(config["warden_socket"])
    end

    def promise_warden_call(connection_name, request)
      Promise.new do |p|
        logger.debug2(request.inspect)
        connection = container.get_connection(connection_name)
        connection.call(request) do |result|
          logger.debug2(result.inspect)

          error = nil

          begin
            response = result.get
          rescue => error
            logger.warn "Request failed: #{request.inspect} file touched: #{file_touch_output} VMstat out: #{vmstat_snapshot_output}"
            logger.log_exception(error)

            p.fail(error)
          else
            p.deliver(response)
          end
        end
      end
    end

    def promise_warden_call_with_retry(connection_name, request)
      Promise.new do |p|
        response = nil
        count = 0

        begin
          response = promise_warden_call(connection_name, request).resolve
        rescue ::EM::Warden::Client::ConnectionError => error
          count += 1
          logger.warn("Request failed: #{request.inspect}, retrying ##{count}.")
          logger.log_exception(error)
          retry
        end

        if count > 0
          logger.debug("Request succeeded after #{count} retries: #{request.inspect}")
        end

        p.deliver(response)
      end
    end

    def paths_to_bind
      []
    end

    def promise_create_container
      Promise.new do |p|
        bind_mounts = paths_to_bind.map do |path|
          bind_mount = ::Warden::Protocol::CreateRequest::BindMount.new
          bind_mount.src_path = path
          bind_mount.dst_path = path
          bind_mount.mode = ::Warden::Protocol::CreateRequest::BindMount::Mode::RO
          bind_mount
        end

        # extra mounts (currently just used for the buildpack cache)
        config["bind_mounts"].each do |bm|
          bind_mount = ::Warden::Protocol::CreateRequest::BindMount.new

          bind_mount.src_path = bm["src_path"]
          bind_mount.dst_path = bm["dst_path"] || bm["src_path"]

          mode = bm["mode"] || "ro"
          bind_mount.mode = BIND_MOUNT_MODE_MAP[mode]

          bind_mounts << bind_mount
        end

        create_request = ::Warden::Protocol::CreateRequest.new
        create_request.bind_mounts = bind_mounts

        response = promise_warden_call(:app, create_request).resolve

        @attributes["warden_handle"] = response.handle
        container.handle = @attributes["warden_handle"]
        logger.user_data[:warden_handle] = response.handle

        p.deliver
      end
    end

    def promise_limit_disk
      Promise.new do |p|
        request = ::Warden::Protocol::LimitDiskRequest.new
        request.handle = container_handle
        request.byte = disk_limit_in_bytes
        promise_warden_call(:app, request).resolve
        p.deliver
      end
    end

    def promise_limit_memory
      Promise.new do |p|
        request = ::Warden::Protocol::LimitMemoryRequest.new
        request.handle = container_handle
        request.limit_in_bytes = memory_limit_in_bytes
        promise_warden_call(:app, request).resolve
        p.deliver
      end
    end

    def container_handle
      @attributes["warden_handle"]
    end

    def promise_warden_run(connection_name, script, privileged=false)
      Promise.new do |p|
        request = ::Warden::Protocol::RunRequest.new
        request.handle = attributes["warden_handle"]
        request.script = script
        request.privileged = privileged
        response = promise_warden_call(connection_name, request).resolve

        if response.exit_status > 0
          data = {
            :script      => script,
            :exit_status => response.exit_status,
            :stdout      => response.stdout,
            :stderr      => response.stderr,
          }

          logger.warn("%s exited with status %d" % [script.inspect, response.exit_status], data)
          p.fail(WardenError.new("Script exited with status %d" % response.exit_status))
        else
          p.deliver(response)
        end
      end
    end

    def promise_container_info
      Promise.new do |p|
        request = ::Warden::Protocol::InfoRequest.new
        request.handle = container_handle

        response =
          begin
            promise_warden_call(:info, request).resolve
          rescue => error
            log(
              :error, "droplet.container-info-retrieval.failed",
              :error => error, :backtrace => error.backtrace)
          end

        p.deliver(response)
      end
    end

    def promise_stop
      Promise.new do |p|
        request = ::Warden::Protocol::StopRequest.new
        request.handle = container_handle
        promise_warden_call(:stop, request).resolve

        p.deliver
      end
    end

    def promise_destroy
      Promise.new do |p|
        request = ::Warden::Protocol::DestroyRequest.new
        request.handle = container_handle

        begin
          promise_warden_call_with_retry(:app, request).resolve
        rescue ::EM::Warden::Client::Error => error
          logger.warn("Error destroying container: #{error.message}")
        end

        # Remove container handle from attributes now that it can no longer be used
        attributes.delete("warden_handle")

        p.deliver
      end
    end

    def destroy(&callback)
      p = Promise.new do
        logger.info("Destroying instance")

        promise_destroy.resolve

        p.deliver
      end

      resolve(p, "destroy instance") do |error, _|
        callback.call(error) unless callback.nil?
      end
    end

    # Resolve a promise making sure that only one runs at a time.
    def resolve(p, name)
      if @busy
        logger.warn("Ignored: #{name}")
        return
      else
        @busy = true

        Promise.resolve(p) do |error, result|
          begin
            took = "took %.3f" % p.elapsed_time

            if error
              logger.warn("Failed: #{name} (#{took})")
              logger.log_exception(error)
            else
              logger.info("Delivered: #{name} (#{took})")
            end

            yield(error, result)
          ensure
            @busy = false
          end
        end
      end
    end

    def copy_out_request(source_path, destination_path)
      FileUtils.mkdir_p(destination_path)

      request = ::Warden::Protocol::CopyOutRequest.new
      request.handle = attributes["warden_handle"]
      request.src_path = source_path
      request.dst_path = destination_path
      request.owner = Process.uid.to_s

      begin
        promise_warden_call_with_retry(:app, request).resolve
      rescue ::EM::Warden::Client::Error => error
        logger.warn("Error copying files out of container: #{error.message}")
      end
    end

    def consuming_memory?
      true
    end

    def consuming_disk?
      true
    end

    private

    def file_touch_output
      FileUtils.touch(File.join(config["base_dir"], "tmp", "test_promise_warden_call")) && "passed"
    rescue
      "failed"
    end

    def vmstat_snapshot_output
      Vmstat.snapshot.inspect
    rescue
      "Unable to get Vmstat.snapshot"
    end
  end
end
