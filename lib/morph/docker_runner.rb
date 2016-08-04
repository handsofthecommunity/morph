# To define Sidekiq::Shutdown
require 'sidekiq/cli'

module Morph
  # More low-level API for running scrapers. Does not do much of the magic
  # and is less opinionated than the higher-level API in Morph::Runner
  class DockerRunner
    ALL_CONFIG_FILENAMES = [
      'Procfile',
      'Gemfile', 'Gemfile.lock',
      'requirements.txt', 'runtime.txt',
      'composer.json', 'composer.lock',
      'app.psgi', 'cpanfile',
      'package.json'
    ]
    BUILDSTEP_IMAGE = 'openaustralia/buildstep'
    DOCKER_NETWORK = 'morph'
    DOCKER_BRIDGE = 'morph'
    DOCKER_NETWORK_SUBNET = '192.168.0.0/16'

    def self.time_file
      '/app/time.output'
    end

    # Memory limit applied to running container (in bytes)
    def self.memory_limit
      512 * 1024 * 1024
    end

    def self.compile_and_start_run(
      repo_path, env_variables, container_labels)
      i = Morph::DockerUtils.get_or_pull_image(BUILDSTEP_IMAGE) do |c|
        yield(:internalout, c)
      end
      # Insert the configuration part of the application code into the container
      i2 = Dir.mktmpdir('morph') do |dest|
        copy_config_to_directory(repo_path, dest, true)
        yield(:internalout, "Injecting configuration and compiling...\n")
        inject_files(i, dest)
      end
      i3 = compile(i2) do |c|
        yield(:internalout, c)
      end
      # If something went wrong during the compile and it couldn't finish
      return [nil, nil] if i3.nil?

      # Before we create a container we need to make sure that there is a
      # special network there for it to be put into
      begin
        Docker::Network.get(DOCKER_NETWORK)
        exists = true
      rescue Docker::Error::NotFoundError
        exists = false
      end
      Docker::Network.create(DOCKER_NETWORK, {
          'Options' => {
            'com.docker.network.bridge.name' => DOCKER_BRIDGE,
            'com.docker.network.bridge.enable_icc' => 'false'
          },
          'IPAM' => {
            'Config' => [{
                'Subnet' => DOCKER_NETWORK_SUBNET
            }]
          }
        }) unless exists

      command = Morph::TimeCommand.command(['/start', 'scraper'], time_file)

      # TODO: Also copy back time output file and the sqlite journal file
      # The sqlite journal file won't be present most of the time

      container_options = {
        'Cmd' => command,
        'Image' => i3.id,
        # See explanation in https://github.com/openaustralia/morph/issues/242
        'CpuShares' => 307,
        'Memory' => memory_limit,
        'Env' =>
          {
            'REQUESTS_CA_BUNDLE' => '/etc/ssl/certs/ca-certificates.crt'
          }.merge(env_variables).map { |k, v| "#{k}=#{v}" },
        'Labels' => container_labels,
        'HostConfig' => {
          # Attach this container to our special network morph
          'NetworkMode' => DOCKER_NETWORK
        }
      }

      c = Docker::Container.create(container_options)

      Dir.mktmpdir('morph') do |dest|
        copy_config_to_directory(repo_path, dest, false)
        yield(:internalout, "Injecting scraper and running...\n")
        Morph::DockerUtils.insert_contents_of_directory(c, dest, "/app")
      end

      c.start
      [c, i3]
    end

    # If since is non-nil only return log lines since the time given. This
    # time is non-inclusive so we shouldn't return the log line with that
    # exact timestamp, just ones after it.
    def self.attach_to_run_and_finish(container, files, since = nil, max_lines = nil)
      params = {stdout: true, stderr: true, follow: true, timestamps: true}
      params[:since] = since.to_f if since
      line_count = 0
      container.streaming_logs(params) do |s, line|
        timestamp = Time.parse(line[0..29])
        # To convert this ruby time back to the same string format as it
        # originally came in do: timestamp.utc.strftime('%Y-%m-%dT%H:%M:%S.%9NZ')
        c = line[31..-1]
        # We're going to assume (somewhat rashly, I might add) that the
        # console output from the scraper is always encoded as UTF-8.
        # TODO Something more intelligent. Either figure out the correct encoding...
        # Or take an educated guess rather than making an assumption
        c.force_encoding('UTF-8')
        c.scrub!
        # There is a chance that we catch a log line that shouldn't
        # be included. So...
        if since.nil? || timestamp > since
          if max_lines.nil? || line_count < max_lines
            yield timestamp, s, c
          elsif line_count == max_lines
            yield nil, :internalerr, "\nToo many lines of output! Your scraper will continue uninterrupted. There will just be no further output displayed\n"
          end
          line_count += 1
        end
      end

      # TODO: Don't call container.json multiple times
      status_code = container.json['State']['ExitCode']
      # Wait until container has definitely stopped
      container.wait

      # Make the paths absolute paths for the container
      files = files.map { |f| File.join('/app', f) }

      # Grab the resulting files
      data = Morph::DockerUtils.copy_files(container, files + [time_file])

      # Clean up after ourselves
      container.delete

      time_data = data.delete(time_file)
      if time_data
        time_params = Morph::TimeCommand.params_from_string(time_data)
      end

      # Remove /app from the beginning of all paths in data
      data_with_stripped_paths = {}
      data.each do |path, content|
        stripped_path =
          Pathname.new(path).relative_path_from(Pathname.new('/app')).to_s
        data_with_stripped_paths[stripped_path] = content
      end

      Morph::RunResult.new(status_code, data_with_stripped_paths, time_params)
    end

    # If copy_config is true copies the config file across
    # Otherwise copies the other files across
    def self.copy_config_to_directory(source, dest, copy_config)
      Dir.entries(source).each do |entry|
        next if entry == '.' || entry == '..'

        unless copy_config ^ ALL_CONFIG_FILENAMES.include?(entry)
          FileUtils.copy_entry(File.join(source, entry),
                               File.join(dest, entry))
        end
      end
    end

    def self.update_docker_image!
      Morph::DockerUtils.pull_docker_image(BUILDSTEP_IMAGE)
    end

    private

    def self.docker_build_command(image, commands, dir)
      # Leave the files in dir untouched
      Dir.mktmpdir('morph') do |dir2|
        Morph::DockerUtils.copy_directory_contents(dir, dir2)
        File.open(File.join(dir2, 'Dockerfile'), 'w') do |f|
          f.write dockerfile_contents_from_commands(image, commands)
        end

        Morph::DockerUtils.fix_modification_times(dir2)
        Morph::DockerUtils.docker_build_from_dir(
          dir2, { read_timeout: 5.minutes }) do |c|
          yield c
        end
      end
    end

    def self.dockerfile_contents_from_commands(image, commands)
      commands = [commands] unless commands.is_a?(Array)
      "from #{image.id}\n" + commands.map { |c| c + "\n" }.join
    end

    # Inject all files in the given directory into the /app directory in the
    # image and return a new image
    def self.inject_files(image, dest)
      Dir.mktmpdir('morph') do |dir|
        Morph::DockerUtils.copy_directory_contents(dest, File.join(dir, 'app'))
        docker_build_command(image, ['ADD app /app'], dir) do
          # Note that we're not sending the output of this to the console
          # because it is relatively short running and is otherwise confusing
        end
      end
    end

    # And build
    # TODO: Set memory and cpu limits during compile
    def self.compile(image)
      Dir.mktmpdir('morph') do |dir|
        docker_build_command(
          image,
          [
            # TODO Setting the timeout higher here won't be necessary once we
            # upgrade to a more recent version of herokuish that contains
            # the commit
            # https://github.com/gliderlabs/herokuish/commit/5164f342dfe27537d6fd5425a5121b7ae7925d3c
            # This will probably involve replacing the use of buildstep with
            # using herokuish directly which seems the sensible thing to do now
            'ENV CURL_TIMEOUT 180',
            'ENV NPM_CONFIG_CAFILE /etc/ssl/certs/ca-certificates.crt',
            # Doing this not very nice thing in lieu of figuring out how
            # to set our custom CA cert for all of node
            'ENV NODE_TLS_REJECT_UNAUTHORIZED 0',
            'RUN /build/builder'
          ],
          dir) do |c|
          # We don't want to show the standard docker build output
          unless c =~ /^Step \d+ :/ || c =~ /^ ---> / ||
                 c =~ /^Removing intermediate container / ||
                 c =~ /^Successfully built /
            yield c
          end
        end
      end
    end
  end
end
