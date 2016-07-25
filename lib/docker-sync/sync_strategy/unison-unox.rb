require 'thor/shell'
require 'docker-sync/preconditions'
require 'docker-sync/execution'
require 'open3'
require 'socket'

module Docker_Sync
  module SyncStrategy
    class Unison_Unox
      include Thor::Shell
      include Execution

      @options
      @sync_name
      @watch_thread
      @local_server_pid
      UNISON_CONTAINER_PORT = '5000'
      def initialize(sync_name, options)
        @options = options
        @sync_name = sync_name
        # if a custom image is set, apply it
        if @options.key?('image')
          @docker_image = @options['image']
        else
          @docker_image = 'eugenmayer/unison:unox'
        end
        begin
          Preconditions::unison_available
          Preconditions::unox_available
        rescue Exception => e
          say_status 'error', "#{@sync_name} has been configured to sync with unison, but no unison available", :red
          say_status 'error', e.message, :red
          exit 1
        end
      end

      def run
        start_container
        sync
      end

      def watch
        args = sync_options
        args.push("-repeat watch")
        cmd = 'unison ' + args.join(' ')

        say_status 'command', cmd, :white if @options['verbose']
        forkexec(cmd, "Sync #{@sync_name}", :blue)
      end

      def sync
        args = sync_options
        cmd = 'unison ' + args.join(' ')

        say_status 'command', cmd, :white if @options['verbose']

        stdout, stderr, exit_status = Open3.capture3(cmd)
        if not exit_status.success?
          say_status 'error', "Error starting sync, exit code #{$?.exitstatus}", :red
          say_status 'message', stderr
        else
          say_status 'ok', "Synced #{@options['src']}", :white
          if @options['verbose']
            say_status 'output', stdout
          end
        end
      end

      def sync_options
        args = []

        unless @options['sync_excludes'].nil?
          args = @options['sync_excludes'].map { |pattern| "-ignore='Path #{pattern}'" } + args
        end
        args.push(@options['src'])
        args.push('-auto')
        args.push('-batch')
        args.push(@options['sync_args']) if @options.key?('sync_args')
        sync_host_port = get_host_port(get_container_name, UNISON_CONTAINER_PORT)
        args.push("socket://#{@options['sync_host_ip']}:#{sync_host_port}")

        if @options.key?('sync_group') || @options.key?('sync_groupid')
          raise('Unison does not support sync_user, sync_group, sync_groupid - please use rsync if you need that')
        end
        return args
      end

      def start_container
        say_status 'ok', 'Starting unison', :white
        container_name = get_container_name
        volume_name = get_volume_name
        env = {}

        env['UNISON_EXCLUDES'] = @options['sync_excludes'].map { |pattern| "-ignore='Path #{pattern}'" }.join(' ') if @options.key?('sync_excludes')
        env['UNISON_OWNER'] = @options['sync_user'] if @options.key?('sync_user')
        env['MAX_INOTIFY_WATCHES'] = @options['max_inotify_watches'] if @options.key?('max_inotify_watches')
        if @options['sync_userid'] == 'from_host'
          env['UNISON_OWNER_UID'] = Process.uid
        else
          env['UNISON_OWNER_UID'] = @options['sync_userid'] if @options.key?('sync_userid')
        end

        additional_docker_env = env.map{ |key,value| "-e #{key}=\"#{value}\"" }.join(' ')
        running = `docker ps --filter 'status=running' --filter 'name=#{container_name}' | grep #{container_name}`
        if running == ''
          say_status 'ok', "#{container_name} container not running", :white if @options['verbose']
          exists = `docker ps --filter "status=exited" --filter "name=#{container_name}" | grep #{container_name}`
          if exists == ''
            say_status 'ok', "creating #{container_name} container", :white if @options['verbose']
            run_privileged = '--privileged' if @options.key?('max_inotify_watches') #TODO: replace by the minimum capabilities required
            cmd = "docker run -p '127.0.0.1::#{UNISON_CONTAINER_PORT}' \
                              -v #{volume_name}:#{@options['dest']} \
                              -e UNISON_DIR=#{@options['dest']} \
                              #{additional_docker_env} \
                              #{run_privileged} \
                              --name #{container_name} \
                              -d #{@docker_image}"
          else
            say_status 'ok', "starting #{container_name} container", :white if @options['verbose']
            cmd = "docker start #{container_name} && docker exec #{container_name} supervisorctl restart unison"
          end
        else
          say_status 'ok', "#{container_name} container still running, restarting unison in container", :blue
          cmd = "docker exec #{container_name} supervisorctl restart unison"
        end
        say_status 'command', cmd, :white if @options['verbose']
        `#{cmd}` || raise('Start failed')
        say_status 'ok', "starting initial sync of #{container_name}", :white if @options['verbose']
        # this sleep is needed since the container could be not started
        sleep 5 # TODO: replace with unison -testserver
        sync
        say_status 'success', 'Unison server started', :green
      end

      def get_host_port(container_name, container_port)
        cmd = 'docker inspect --format=" {{ .NetworkSettings.Ports }} " ' + container_name + ' | sed -r "s/.*map\[' + container_port + '[^ ]+\s([0-9]+).*/\1/"'
        say_status 'command', cmd, :white if @options['verbose']
        stdout, stderr, exit_status = Open3.capture3(cmd)
        if not exit_status.success?
          say_status 'command', cmd
          say_status 'error', "Error getting mapped port, exit code #{$?.exitstatus}", :red
          say_status 'message', stderr
        end
        return stdout.gsub("\n",'')
      end

      def get_container_name
        return "#{@sync_name}"
      end

      def get_volume_name
        return @sync_name
      end

      def stop_container
        `docker stop #{get_container_name}`
      end

      def reset_container
        stop_container
        `docker rm #{get_container_name}`
        `docker volume rm #{get_volume_name}`
      end

      def clean
        reset_container
      end

      def stop
        say_status 'ok', "Stopping sync container #{get_container_name}"
        begin
          stop_container
        rescue Exception => e
          say_status 'error', "Stopping failed of #{get_container_name}:", :red
          puts e.message
        end
      end
    end
  end
end
