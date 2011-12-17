# encoding: utf-8

##
# Build the Backup Command Line Interface using Thor
module Backup
  module CLI
    class Utility < Thor
      include Thor::Actions

      ##
      # [Perform]
      # Performs the backup process. The only required option is the --trigger [-t].
      # If the other options (--config-file, --data-path, --cache--path, --tmp-path) aren't specified
      # they will fallback to the (good) defaults
      #
      # If --root-path is given, it will be used as the base (Backup::PATH) for our defaults,
      # as well as the base path for any option specified as a relative path.
      # Any option given as an absolute path will be used "as-is".
      method_option :trigger,         :type => :string,  :required => true, :aliases => ['-t', '--triggers']
      method_option :config_file,     :type => :string,  :default => '',    :aliases => '-c'
      method_option :root_path,       :type => :string,  :default => '',    :aliases => '-r'
      method_option :data_path,       :type => :string,  :default => '',    :aliases => '-d'
      method_option :log_path,        :type => :string,  :default => '',    :aliases => '-l'
      method_option :cache_path,      :type => :string,  :default => ''
      method_option :tmp_path,        :type => :string,  :default => ''
      method_option :quiet,           :type => :boolean, :default => false, :aliases => '-q'
      desc 'perform', "Performs the backup for the specified trigger.\n" +
                      "You may perform multiple backups by providing multiple triggers, separated by commas.\n\n" +
                      "Example:\n\s\s$ backup perform --triggers backup1,backup2,backup3,backup4\n\n" +
                      "This will invoke 4 backups, and they will run in the order specified (not asynchronous)."
      def perform
        ##
        # Setup required paths based on the given options
        setup_paths(options)

        ##
        # Silence Backup::Logger from printing to STDOUT, if --quiet was specified
        Logger.send(:const_set, :QUIET, options[:quiet])

        ##
        # Prepare all trigger names by splitting them by ','
        # and finding trigger names matching wildcard
        triggers = options[:trigger].split(",")
        triggers.map!(&:strip).map!{ |t|
          t.include?(Backup::Finder::WILDCARD) ?
            Backup::Finder.new(t).matching : t
        }.flatten!

        ##
        # Process each trigger
        triggers.each do |trigger|

          ##
          # Defines the TRIGGER constant
          Backup.send(:const_set, :TRIGGER, trigger)

          ##
          # Define the TIME constants
          Backup.send(:const_set, :TIME, Time.now.strftime("%Y.%m.%d.%H.%M.%S"))

          ##
          # Ensure DATA_PATH and DATA_PATH/TRIGGER are created if they do not yet exist
          FileUtils.mkdir_p(File.join(Backup::DATA_PATH, Backup::TRIGGER))

          ##
          # Parses the backup configuration file and returns the model instance by trigger
          model = Backup::Finder.new(trigger).find

          ##
          # Runs the returned model
          Logger.message "Performing backup for #{model.label}!"
          model.perform!

          ##
          # Removes the TRIGGER constant
          Backup.send(:remove_const, :TRIGGER) if defined? Backup::TRIGGER

          ##
          # Removes the TIME constant
          Backup.send(:remove_const, :TIME) if defined? Backup::TIME

          ##
          # Reset the Backup::Model.current to nil for the next potential run
          Backup::Model.current = nil

          ##
          # Clear the Log Messages for the next potential run
          Logger.clear!

          ##
          # Reset the Backup::Model.extension to 'tar' so it's at its
          # initial state when the next Backup::Model initializes
          Backup::Model.extension = 'tar'
        end

      rescue => err
        Logger.error Backup::Errors::CLIError.wrap(err)
        exit(1)
      end

      ##
      # [Generate:Model]
      # Generates a model configuration file based on the arguments passed in.
      # For example:
      #   $ backup generate:model --trigger my_backup --databases='mongodb'
      # will generate a pre-populated model with a base MongoDB setup
      method_option :trigger,     :type => :string, :required => true
      method_option :config_path, :type => :string,
                    :desc => 'Path to your Backup configuration directory'
      desc 'generate:model', "Generates a Backup model file\n\n" +
          "Note:\n" +
          "\s\s'--config-path' is the path to the directory where 'config.rb' is located.\n" +
          "\s\sThe model file will be created as '<config_path>/models/<trigger>.rb'\n" +
          "\s\sDefault: #{Backup::PATH}\n"

      # options with their available values
      %w{ databases storages syncers
          encryptors compressors notifiers }.map(&:to_sym).each do |name|
        path = File.join(Backup::TEMPLATE_PATH, 'cli', 'utility', name.to_s[0..-2])
        method_option name, :type => :string, :desc =>
            "(#{Dir[path + '/*'].sort.map {|p| File.basename(p) }.join(', ')})"
      end

      method_option :archives,    :type => :boolean
      method_option :splitter,    :type => :boolean, :default => true,
                    :desc => "use `--no-splitter` to disable"

      define_method "generate:model" do
        opts = options.merge(
          :trigger      => options[:trigger].gsub(/[\W\s]/, '_'),
          :config_path  => options[:config_path] ? File.expand_path(options[:config_path]) : nil
        )
        config_path    = opts[:config_path] || Backup::PATH
        models_path    = File.join(config_path, "models")
        config         = File.join(config_path, "config.rb")
        model          = File.join(models_path, "#{opts[:trigger]}.rb")

        FileUtils.mkdir_p(models_path)
        if overwrite?(model)
          File.open(model, 'w') do |file|
            file.write(Backup::Template.new({:options => opts}).
                       result("cli/utility/model.erb"))
          end
          puts "Generated model file in '#{ model }'."
        end

        if not File.exist?(config)
          File.open(config, "w") do |file|
            file.write(Backup::Template.new.result("cli/utility/config"))
          end
          puts "Generated configuration file in '#{ config }'."
        end
      end

      ##
      # [Generate:Config]
      # Generates the main configuration file
      desc 'generate:config', 'Generates the main Backup bootstrap/configuration file'
      method_option :path, :type => :string
      define_method 'generate:config' do
        path = options[:path] ? File.expand_path(options[:path]) : nil
        config_path = path || Backup::PATH
        config      = File.join(config_path, "config.rb")

        FileUtils.mkdir_p(config_path)
        if overwrite?(config)
          File.open(config, "w") do |file|
            file.write(Backup::Template.new.result("cli/utility/config"))
          end
          puts "Generated configuration file in '#{ config }'"
        end
      end

      ##
      # [Decrypt]
      # Shorthand for decrypting encrypted files
      desc 'decrypt', 'Decrypts encrypted files'
      method_option :encryptor,     :type => :string,  :required => true
      method_option :in,            :type => :string,  :required => true
      method_option :out,           :type => :string,  :required => true
      method_option :base64,        :type => :boolean, :default  => false
      method_option :password_file, :type => :string,  :default  => ''
      method_option :salt,          :type => :boolean, :default  => false
      def decrypt
        case options[:encryptor].downcase
        when 'openssl'
          base64   = options[:base64] ? '-base64' : ''
          password = options[:password_file] ? "-pass file:#{options[:password_file]}" : ''
          salt     = options[:salt] ? '-salt' : ''
          %x[openssl aes-256-cbc -d #{base64} #{password} #{salt} -in '#{options[:in]}' -out '#{options[:out]}']
        when 'gpg'
          %x[gpg -o '#{options[:out]}' -d '#{options[:in]}']
        else
          puts "Unknown encryptor: #{options[:encryptor]}"
          puts "Use either 'openssl' or 'gpg'"
        end
      end

      ##
      # [Dependencies]
      # Returns a list of Backup's dependencies
      desc 'dependencies', 'Display the list of dependencies for Backup, or install them through Backup.'
      method_option :install, :type => :string
      method_option :list,    :type => :boolean
      def dependencies
        unless options.any?
          puts
          puts "To display a list of available dependencies, run:\n\n"
          puts "  backup dependencies --list"
          puts
          puts "To install one of these dependencies (with the correct version), run:\n\n"
          puts "  backup dependencies --install <name>"
          exit
        end

        if options[:list]
          Backup::Dependency.all.each do |name, gemspec|
            puts
            puts name
            puts "--------------------------------------------------"
            puts "version:       #{gemspec[:version]}"
            puts "lib required:  #{gemspec[:require]}"
            puts "used for:      #{gemspec[:for]}"
          end
        end

        if options[:install]
          puts
          puts "Installing \"#{options[:install]}\" version \"#{Backup::Dependency.all[options[:install]][:version]}\".."
          puts "If this doesn't work, please issue the following command yourself:\n\n"
          puts "  gem install #{options[:install]} -v '#{Backup::Dependency.all[options[:install]][:version]}'\n\n"
          puts "Please wait..\n\n"
          puts %x[gem install #{options[:install]} -v '#{Backup::Dependency.all[options[:install]][:version]}']
        end
      end

      ##
      # [Version]
      # Returns the current version of the Backup gem
      map '-v' => :version
      desc 'version', 'Display installed Backup version'
      def version
        puts "Backup #{Backup::Version.current}"
      end

      private

      ##
      # Setup required paths based on the given options
      #
      def setup_paths(options)
        ##
        # Set PATH if --root-path is given and the directory exists
        root_path = false
        root_given = options[:root_path].strip
        if !root_given.empty? && File.directory?(root_given)
          root_path = File.expand_path(root_given)
          Backup.send(:remove_const, :PATH)
          Backup.send(:const_set, :PATH, root_path)
        end

        ##
        # Update all defaults and given paths to use root_path (if given).
        # Paths given as an absolute path will be used 'as-is'
        { :config_file  => 'config.rb',
          :data_path    => 'data',
          :log_path     => 'log',
          :cache_path   => '.cache',
          :tmp_path     => '.tmp' }.each do |key, name|
          # strip any trailing '/' in case the user supplied this as part of
          # an absolute path, so we can match it against File.expand_path()
          given = options[key].sub(/\/\s*$/, '').lstrip
          path = false
          if given.empty?
            path = File.join(root_path, name) if root_path
          else
            path = File.expand_path(given)
            unless given == path
              path = File.join(root_path, given) if root_path
            end
          end

          const = key.to_s.upcase
          if path
            Backup.send(:remove_const, const)
            Backup.send(:const_set, const, path)
          else
            path = Backup.const_get(const)
          end

          ##
          # Ensure the LOG_PATH, CACHE_PATH and TMP_PATH are created if they do not yet exist
          FileUtils.mkdir_p(path) if [:log_path, :cache_path, :tmp_path].include?(key)
        end
      end

      ##
      # Helper method for asking the user if he/she wants to overwrite the file
      def overwrite?(path)
        if File.exist?(path)
          return yes? "A file already exists at '#{ path }'. Do you want to overwrite? [y/n]"
        end
        true
      end

    end
  end
end
