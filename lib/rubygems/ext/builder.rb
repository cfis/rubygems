# frozen_string_literal: true

#--
# Copyright 2006 by Chad Fowler, Rich Kilmer, Jim Weirich and others.
# All rights reserved.
# See LICENSE.txt for permissions.
#++

require_relative "../user_interaction"

class Gem::Ext::Builder
  include Gem::UserInteraction

  attr_accessor :build_args # :nodoc:

  def self.class_name
    name =~ /Ext::(.*)Builder/
    $1.downcase
  end

  def self.make(dest_path, results, make_dir = Dir.pwd, sitedir = nil, targets = ["clean", "", "install"],
    target_rbconfig: Gem.target_rbconfig)
    unless File.exist? File.join(make_dir, "Makefile")
      raise Gem::InstallError, "Makefile not found"
    end

    # try to find make program from Ruby configure arguments first
    target_rbconfig["configure_args"] =~ /with-make-prog\=(\w+)/
    make_program_name = ENV["MAKE"] || ENV["make"] || $1
    make_program_name ||= RUBY_PLATFORM.include?("mswin") ? "nmake" : "make"
    make_program = shellsplit(make_program_name)

    # The installation of the bundled gems is failed when DESTDIR is empty in mswin platform.
    destdir = /\bnmake/i !~ make_program_name || ENV["DESTDIR"] && ENV["DESTDIR"] != "" ? format("DESTDIR=%s", ENV["DESTDIR"]) : ""

    env = [destdir]

    if sitedir
      env << format("sitearchdir=%s", sitedir)
      env << format("sitelibdir=%s", sitedir)
    end

    targets.each do |target|
      # Pass DESTDIR via command line to override what's in MAKEFLAGS
      cmd = [
        *make_program,
        *env,
        target,
      ].reject(&:empty?)
      begin
        run(cmd, results, "make #{target}".rstrip, make_dir)
      rescue Gem::InstallError
        raise unless target == "clean" # ignore clean failure
      end
    end
  end

  def self.ruby
    # Gem.ruby is quoted if it contains whitespace
    cmd = shellsplit(Gem.ruby)

    # This load_path is only needed when running rubygems test without a proper installation.
    # Prepending it in a normal installation will cause problem with order of $LOAD_PATH.
    # Therefore only add load_path if it is not present in the default $LOAD_PATH.
    load_path = File.expand_path("../..", __dir__)
    case load_path
    when RbConfig::CONFIG["sitelibdir"], RbConfig::CONFIG["vendorlibdir"], RbConfig::CONFIG["rubylibdir"]
      cmd
    else
      cmd << "-I#{load_path}"
    end
  end

  def self.run(command, results, command_name = nil, dir = Dir.pwd, env = {})
    verbose = Gem.configuration.really_verbose

    begin
      rubygems_gemdeps = ENV["RUBYGEMS_GEMDEPS"]
      ENV["RUBYGEMS_GEMDEPS"] = nil
      if verbose
        puts("current directory: #{dir}")
        p(command)
      end
      results << "current directory: #{dir}"
      results << shelljoin(command)

      require "open3"
      # Set $SOURCE_DATE_EPOCH for the subprocess.
      build_env = { "SOURCE_DATE_EPOCH" => Gem.source_date_epoch_string }.merge(env)
      output, status = begin
                         Open3.popen2e(build_env, *command, chdir: dir) do |_stdin, stdouterr, wait_thread|
                           output = String.new
                           while line = stdouterr.gets
                             output << line
                             if verbose
                               print line
                             end
                           end
                           [output, wait_thread.value]
                         end
                       rescue StandardError => error
                         raise Gem::InstallError, "#{command_name || class_name} failed#{error.message}"
                       end
      unless verbose
        results << output
      end
    ensure
      ENV["RUBYGEMS_GEMDEPS"] = rubygems_gemdeps
    end

    unless status.success?
      results << "Building has failed. See above output for more information on the failure." if verbose
    end

    yield(status, results) if block_given?

    unless status.success?
      exit_reason =
        if status.exited?
          ", exit code #{status.exitstatus}"
        elsif status.signaled?
          ", uncaught signal #{status.termsig}"
        end

      raise Gem::InstallError, "#{command_name || class_name} failed#{exit_reason}"
    end
  end

  def self.shellsplit(command)
    require "shellwords"

    Shellwords.split(command)
  end

  def self.shelljoin(command)
    require "shellwords"

    Shellwords.join(command)
  end

  ##
  # Creates a new extension builder for +spec+.  If the +spec+ does not yet
  # have build arguments, saved, set +build_args+ which is an ARGV-style
  # array.

  def initialize(spec, build_args = spec.build_args, target_rbconfig = Gem.target_rbconfig)
    @spec       = spec
    @build_args = build_args
    @gem_dir    = spec.full_gem_path
    @target_rbconfig = target_rbconfig

    @ran_rake = false
  end

  ##
  # Chooses the extension builder class for +extension+

  def builder_for(extension) # :nodoc:
    case extension
    when /extconf/ then
      Gem::Ext::ExtConfBuilder
    when /configure/ then
      Gem::Ext::ConfigureBuilder
    when /rakefile/i, /mkrf_conf/i then
      @ran_rake = true
      Gem::Ext::RakeBuilder
    when /CMakeLists.txt/ then
      Gem::Ext::CmakeBuilder.new
    when /Cargo.toml/ then
      Gem::Ext::CargoBuilder.new
    else
      build_error("No builder for extension '#{extension}'")
    end
  end

  ##
  # Logs the build +output+, then raises Gem::Ext::BuildError.

  def build_error(output, backtrace = nil) # :nodoc:
    gem_make_out = write_gem_make_out output

    message = <<-EOF
ERROR: Failed to build gem native extension.

    #{output}

Gem files will remain installed in #{@gem_dir} for inspection.
Results logged to #{gem_make_out}
EOF

    raise Gem::Ext::BuildError, message, backtrace
  end

  def build_extension(extension, dest_path) # :nodoc:
    results = []

    builder = builder_for(extension)

    extension_dir =
      File.expand_path File.join(@gem_dir, File.dirname(extension))
    lib_dir = File.join @spec.full_gem_path, @spec.raw_require_paths.first

    begin
      FileUtils.mkdir_p dest_path

      results = builder.build(extension, dest_path,
                              results, @build_args, lib_dir, extension_dir, @target_rbconfig)

      verbose { results.join("\n") }

      write_gem_make_out results.join "\n"
    rescue StandardError => e
      results << e.message
      build_error(results.join("\n"), $@)
    end
  end

  ##
  # Builds extensions.  Valid types of extensions are extconf.rb files,
  # configure scripts and rakefiles or mkrf_conf files.

  def build_extensions
    return if @spec.extensions.empty?

    if @build_args.empty?
      say "Building native extensions. This could take a while..."
    else
      say "Building native extensions with: '#{@build_args.join " "}'"
      say "This could take a while..."
    end

    dest_path = @spec.extension_dir

    require "fileutils"
    FileUtils.rm_f @spec.gem_build_complete_path

    @spec.extensions.each do |extension|
      break if @ran_rake

      build_extension extension, dest_path
    end

    FileUtils.touch @spec.gem_build_complete_path
  end

  ##
  # Writes +output+ to gem_make.out in the extension install directory.

  def write_gem_make_out(output) # :nodoc:
    destination = File.join @spec.extension_dir, "gem_make.out"

    FileUtils.mkdir_p @spec.extension_dir

    File.open destination, "wb" do |io|
      io.puts output
    end

    destination
  end
end
