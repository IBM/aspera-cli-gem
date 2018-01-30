require 'asperalm/log'
require 'asperalm/operating_system'
require 'singleton'
require 'xmlsimple'

module Asperalm
  module Fasp
    # locate Aspera transfer products based on OS
    # then identifies resources (binary, keys..)
    class Installation
      include Singleton
      VARRUN_SUBFOLDER='var/run'
      FIRST_FOUND=:first

      # name of Aspera application to be used
      attr_reader :activated
      def activated=(value)
        @activated=value
        # installed paths
        @i_p=nil
      end

      def initialize
        @i_p=nil
        @found_products=nil
        @activated=FIRST_FOUND
      end

      # a user can set an alternate location, example:
      #      { :expected=>'Enterprise Server',
      #        :ascp=>'ascp',
      #        :app_root=>'/Library/Aspera',
      #        :run_root=>File.join(Dir.home,'Library','Application Support','Aspera','Enterprise Server'),
      #        :log_root=>File.join(Dir.home,'Library','Logs','Aspera'),
      #        :sub_bin=>'bin',
      #        :sub_keys=>'var',
      #        :dsa=>'aspera_tokenauth_id_dsa'}
      def set_location(p)
        @i_p={}
        @i_p[:ascp] = { :path =>File.join(p[:app_root],p[:sub_bin],p[:ascp]), :type => :file, :required => true}
        @i_p[:ssh_bypass_key_dsa] = { :path =>File.join(p[:app_root],p[:sub_keys],p[:dsa]), :type => :file, :required => true}
        @i_p[:ssh_bypass_key_rsa] = { :path =>File.join(p[:app_root],p[:sub_keys],'aspera_tokenauth_id_rsa'), :type => :file, :required => true}
        @i_p[:fallback_cert] = { :path =>File.join(p[:app_root],p[:sub_keys],'aspera_web_cert.pem'), :type => :file, :required => false}
        @i_p[:fallback_key] = { :path =>File.join(p[:app_root],p[:sub_keys],'aspera_web_key.pem'), :type => :file, :required => false}
        @i_p[:localhost_cert] = { :path =>File.join(p[:app_root],p[:sub_keys],'localhost.crt'), :type => :file, :required => false}
        @i_p[:localhost_key] = { :path =>File.join(p[:app_root],p[:sub_keys],'localhost.key'), :type => :file, :required => false}
        @i_p[:plugin_https_port_file] = { :path =>File.join(p[:run_root],VARRUN_SUBFOLDER,'https.uri'), :type => :file, :required => false}
        @i_p[:log_folder] = { :path =>p[:log_root], :type => :folder, :required => false}
        Log.log.debug "resources=#{@i_p}"
        notfound=[]
        @i_p.each_pair do |k,v|
          notfound.push(k) if v[:type].eql?(:file) and v[:required] and ! File.exist?(v[:path])
        end
        if !notfound.empty?
          reslist=notfound.map { |k| "#{k.to_s}: #{@i_p[k][:path]}"}.join("\n")
          raise StandardError.new("Please check your connect client installation, Cannot locate resource(s):\n#{reslist}")
        end
      end

      # installation paths
      # get fasp resource files paths
      def paths
        return @i_p unless @i_p.nil?
        # this contains var/run, files generated on runtime
        if @activated.eql?(FIRST_FOUND)
          p = installed_products.first
        else
          p=installed_products.select{|p|p[:name].eql?(@activated)}.first
        end
        raise "no FASP installation found\nPlease check manual on how to install FASP." if p.nil?
        set_location(p)
        return @i_p
      end

      # user can set all path directly
      def paths=(path_set)
        raise "must be a hash" if !path_set.is_a?(Hash)
        @i_p=path_set
      end

      # get path of one resource file
      def path(k)
        file=paths[k][:path]
        raise "no such file: #{file}" if !File.exist?(file)
        return file
      end

      # returns product folders depending on OS
      def product_locations
        common_places=[]
        case OperatingSystem.current_os_type
        when :mac
          common_places.push({
            :expected=>'Connect Client',
            :ascp=>'ascp',
            :app_root=>File.join(Dir.home,'Applications','Aspera Connect.app'),
            :run_root=>File.join(Dir.home,'Library','Application Support','Aspera','Aspera Connect'),
            :log_root=>File.join(Dir.home,'Library','Logs','Aspera'),
            :sub_bin=>File.join('Contents','Resources'),
            :sub_keys=>File.join('Contents','Resources'),
            :dsa=>'asperaweb_id_dsa.openssh'})
          common_places.push({
            :expected=>'Enterprise Server',
            :ascp=>'ascp',
            :app_root=>'/Library/Aspera',
            :run_root=>File.join(Dir.home,'Library','Application Support','Aspera','Enterprise Server'),
            :log_root=>File.join(Dir.home,'Library','Logs','Aspera'),
            :sub_bin=>'bin',
            :sub_keys=>'var',
            :dsa=>'aspera_tokenauth_id_dsa'})
          common_places.push({
            :expected=>'Aspera CLI',
            :ascp=>'ascp',
            :app_root=>File.join(Dir.home,'Applications','Aspera CLI'),
            :run_root=>File.join(Dir.home,'Library','Application Support','Aspera','Aspera Connect'),
            :log_root=>File.join(Dir.home,'Library','Logs','Aspera'),
            :sub_bin=>File.join('bin'),
            :sub_keys=>File.join('etc'),
            :dsa=>'asperaweb_id_dsa.openssh'})
        when :windows
          common_places.push({
            :expected=>'Connect Client',
            :ascp=>'ascp.exe',
            :app_root=>File.join(ENV['LOCALAPPDATA'],'Programs','Aspera','Aspera Connect'),
            :run_root=>File.join(ENV['LOCALAPPDATA'],'Aspera','Aspera Connect'),
            :sub_bin=>'bin',
            :sub_keys=>'etc',
            :dsa=>'asperaweb_id_dsa.openssh'})
        else  # unix family
          common_places.push({
            :expected=>'Connect Client',
            :ascp=>'ascp',
            :app_root=>File.join(Dir.home,'.aspera','connect'),
            :run_root=>File.join(Dir.home,'.aspera','connect'),
            :sub_bin=>'bin',
            :sub_keys=>'etc',
            :dsa=>'asperaweb_id_dsa.openssh'})
          common_places.push({
            :expected=>'Enterprise Server',
            :ascp=>'ascp',
            :app_root=>'/opt/aspera',
            :run_root=>'/opt/aspera',
            :sub_bin=>'bin',
            :sub_keys=>'var',
            :dsa=>'aspera_tokenauth_id_dsa'})
        end
        return common_places
      end

      # try to find connect client or other Aspera product installed.
      def installed_products
        return @found_products unless @found_products.nil?
        @found_products=product_locations.select do |l|
          next false unless Dir.exist?(l[:app_root])
          product_info_file="#{l[:app_root]}/product-info.mf"
          if File.exist?(product_info_file)
            res_s=XmlSimple.xml_in(File.read(product_info_file),{"ForceArray"=>false})
            l[:name]=res_s['name']
            l[:version]=res_s['version']
          else
            l[:name]=l[:expected]
          end
          true # select this version
        end
      end
    end # Installation
  end # Fasp
end # Asperalm
