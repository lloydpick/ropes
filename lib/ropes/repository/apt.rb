require 'debeasy'
require 'stringio'
require 'zlib'
require 'tempfile'
require 'digest'
require 'gpgme'
require 'uuid'

module Ropes

  class Error < RuntimeError; end
  class InvalidRepositoryType < Error; end

  module Repository
    class Apt
    
      def initialize(options)
        missing_options = %w{
          origin 
          type 
          distribution 
          version 
          architectures 
          components 
          description
          package_base}.reject do |required_option|
            options.has_key?(required_option.to_sym)
        end

        raise "Missing options: #{missing_options.join(", ")}" unless missing_options.empty?

        raise Error, "Architectures must be an array" unless options[:architectures].is_a? Array

        @release_file     = nil
        @packages_file     = nil
        @packages_field_gz = nil

        @options = options
        @packages = []
        @field_order = %w{
          package
          priority
          section
          installed_size
          maintainer
          architecture
          source
          version
          depends
          filename
          size
          MD5sum
          SHA1
          SHA256
          description
          description-md5
          bugs
          origin
          supported
        }
        @mandatory_fields = %w{
          package
          version
          architecture
          maintainer
          description
        }
      end

      def add_file_by_path(path)
        metadata = Debeasy.read(path).to_hash
        if validate_metadata(metadata).empty?
          @packages << metadata
        else
          raise "Missing mandatory fields on package: #{validate_metadata(metadata).join(", ")}"
        end
      end

      def add_file_by_info(package)
        if validate_metadata(package).empty?
          if package.is_a? Hash
            @packages << package
          else
            raise "Package metadata must be in hash format"
          end
        else
          raise "Missing mandatory fields on package: #{validate_metadata(package).join(", ")}"
        end
      end

      # Get the Packages file as a string

      def packages_file(arch)
        packages_for_arch = @packages.select {|p| p["architecture"] == arch}
        entries = packages_for_arch.map do |package|
          lines = []
          @field_order.each do |field|
            if package[field] != nil
              case field
              when "filename"
                lines << packages_line(field.capitalize, "#{@options[:package_base]}/#{package[field]}") 
              when "installed_size"
                lines << packages_line("Installed-Size", package[field])
              when "SHA1", "SHA256", "MD5sum"
                lines << packages_line(field, package[field])
              else
                lines << packages_line(field.capitalize, package[field])
              end
            end
          end
          lines.join("\n")
        end
        if entries.empty?
          ""
        else
          entries.join("\n\n") + "\n"
        end
      end

      # Get the Packages file as a gzip'ed string

      def packages_file_gz(arch)
        io = StringIO.new("w")
        gz = Zlib::GzipWriter.new(io)
        gz.write(packages_file(arch))
        gz.close
        io.string
      end

      # Get the Release file as a string

      def release_file 
        lines = []
        lines << "Origin: #{@options[:origin]}"
        lines << "Label: #{@options[:origin]}"
        lines << "Suite: #{@options[:distribution]}"
        lines << "Version: #{@options[:version]}"
        lines << "Codename: #{@options[:distribution]}"
        lines << "Date: #{Time.new.utc.strftime '%a, %d %b %Y %H:%M:%S UTC'}"
        lines << "Architectures: #{@options[:architectures].join(" ")}"
        lines << "Components: #{@options[:components]}"
        lines << "Description: #{@options[:description]}"
        lines << "MD5Sum:"
        @options[:architectures].each do |arch|
          # Have to create the files in real life to get the real size
          temp_packages_file = Tempfile.new("Packages")
          temp_packages_file.write packages_file(arch)
          temp_packages_file_gz = Tempfile.new("Packages.gz")
          temp_packages_file_gz.write packages_file_gz(arch)
          lines << " #{Digest::MD5.hexdigest(packages_file(arch))}                   #{temp_packages_file.size} #{@options[:components]}/binary-#{arch}/Packages"
          lines << " #{Digest::MD5.hexdigest(packages_file_gz(arch))}                   #{temp_packages_file_gz.size} #{@options[:components]}/binary-#{arch}/Packages.gz"
        end
        lines.join("\n") + "\n"
      end

      # Get detached GPG signature of Release file

      def release_file_gpg(path_to_gpgkey)
        GPGME::Key.import(File.open(path_to_gpgkey))
        GPGME::Crypto.new.sign(release_file, {
          :mode => GPGME::SIG_MODE_DETACH,
          :armor => true
        })
      end

      private


      def packages_line(field, value)
        "#{field}: #{value}"
      end

      def validate_metadata(metadata_hash)
        @mandatory_fields.reject {|field| metadata_hash.has_key?(field)}
      end

    end
  end
end
