require 'asperalm/cli/plugin'

module Asperalm
  module Cli
    module Plugins
      class Node < Plugin
        attr_accessor :faspmanager

        def set_options
          @option_parser.add_opt_simple(:url,"-wURI", "--url=URI","URL of application, e.g. http://org.asperafiles.com")
          @option_parser.add_opt_simple(:username,"-uSTRING", "--username=STRING","username to log in")
          @option_parser.add_opt_simple(:password,"-pSTRING", "--password=STRING","password")
          @option_parser.set_option(:persistency,File.join($PROGRAM_FOLDER,"persistency_cleanup.txt"))
          @option_parser.add_opt_simple(:persistency,"--persistency=FILEPATH","persistency file")
          @option_parser.add_opt_simple(:transfer_filter,"--transfer-filter=EXPRESSION","Ruby expression for filter at transfer level")
          @option_parser.add_opt_simple(:file_filter,"--file-filter=EXPRESSION","Ruby expression for filter at file level")
        end

        def dojob
          command=@option_parser.get_next_arg_from_list('command',[ :browse, :upload, :download, :transfers, :info, :cleanup ])
          api_node=Rest.new(@option_parser.get_option_mandatory(:url),{:basic_auth=>{:user=>@option_parser.get_option_mandatory(:username), :password=>@option_parser.get_option_mandatory(:password)}})
          case command
          when :browse
            thepath=@option_parser.get_next_arg_value("path")
            send_result=api_node.call({:operation=>'POST',:subpath=>'files/browse',:json_params=>{ :path => thepath} } )
            return nil if !send_result[:data].has_key?('items')
            return {:fields=>send_result[:data]['items'].first.keys,:values=>send_result[:data]['items']}
          when :upload
            filelist = @option_parser.get_remaining_arguments("file list")
            Log.log.debug("file list=#{filelist}")
            raise CliBadArgument,"Missing source(s) and destination" if filelist.length < 2
            destination=filelist.pop
            send_result=api_node.call({:operation=>'POST',:subpath=>'files/upload_setup',:json_params=>{ :transfer_requests => [ { :transfer_request => { :paths => [ { :destination => destination } ] } } ] }})
            raise send_result[:data]['transfer_specs'][0]['error']['user_message'] if send_result[:data]['transfer_specs'][0].has_key?('error')
            raise "expecting one session exactly" if send_result[:data]['transfer_specs'].length != 1
            transfer_spec=send_result[:data]['transfer_specs'].first['transfer_spec']
            transfer_spec['paths']=filelist.map { |i| {'source'=>i} }
            @faspmanager.transfer_with_spec(transfer_spec)
            return nil
          when :download
            filelist = @option_parser.get_remaining_arguments("file list")
            Log.log.debug("file list=#{filelist}")
            raise CliBadArgument,"Missing source(s) and destination" if filelist.length < 2
            destination=filelist.pop
            send_result=api_node.call({:operation=>'POST',:subpath=>'files/download_setup',:json_params=>{ :transfer_requests => [ { :transfer_request => { :paths => filelist.map {|i| {:source=>i}; } } } ] }})
            raise send_result[:data]['transfer_specs'][0]['error']['user_message'] if send_result[:data]['transfer_specs'][0].has_key?('error')
            raise "expecting one session exactly" if send_result[:data]['transfer_specs'].length != 1
            transfer_spec=send_result[:data]['transfer_specs'].first['transfer_spec']
            @faspmanager.transfer_with_spec(transfer_spec)
            return nil
          when :transfers
            command=@option_parser.get_next_arg_from_list('command',[ :list ])
            # ,:url_params=>{:active_only=>true}
            resp=api_node.call({:operation=>'GET',:subpath=>'ops/transfers',:headers=>{'Accept'=>'application/json'}})
            return resp[:data] # TODO
          when :info
            resp=api_node.call({:operation=>'GET',:subpath=>'info',:headers=>{'Accept'=>'application/json'}})
            return resp[:data] # TODO
          when :cleanup
            persistencyfile=@option_parser.get_option_mandatory(:persistency)
            transfer_filter=@option_parser.get_option_mandatory(:transfer_filter)
            file_filter=@option_parser.get_option_mandatory(:file_filter)
            Log.log.debug("transfer_filter: #{transfer_filter}")
            Log.log.debug("file_filter: #{file_filter}")
            # first time run ? or subsequent run ?
            iteration_token=nil
            if File.exist?(persistencyfile)
              iteration_token=File.read(persistencyfile)
            end
            params={:active_only=>false}
            params[:iteration_token]=iteration_token unless iteration_token.nil?
            resp=api_node.list('ops/transfers',params)
            transfers=resp[:data]
            if transfers.is_a?(Array) then
              # 3.7.2, released API
              iteration_token=URI.decode_www_form(URI.parse(resp[:http]['Link'].match(/<([^>]+)>/)[1]).query).to_h['iteration_token']
            else
              # 3.5.2, deprecated API
              iteration_token=transfers['iteration_token']
              transfers=transfers['transfers']
            end
            File.write(persistencyfile,iteration_token)
            # build list of files to delete: non zero files, downloads, for specified user
            paths_to_delete=[]
            transfers.each do |t|
              if eval(transfer_filter)
                t['files'].each do |f|
                  if eval(file_filter)
                    paths_to_delete.push({'path'=>'/'+f['path']})
                    Log.log.info("to delete: #{f['path']}")
                  end
                end
              end
            end
            # delete files, if any
            if paths_to_delete.length != 0
              Log.log.info("deletion")
              resp=api_node.call({:operation=>'POST',:subpath=>'files/delete',:json_params=>{:paths=>paths_to_delete}})
              #resp=api_node.create('files/delete',{:paths=>paths_to_delete})
              resres={:fields=>['file','result'],:values=>[]}
              JSON.parse(resp[:http].body)['paths'].each do |p|
                result='deleted'
                if p.has_key?('error')
                  Log.log.error("#{p['error']['user_message']} : #{p['path']}")
                  result="ERR:"+p['error']['user_message']
                end
                resres[:values].push({'file'=>p['path'],'result'=>result})
              end
              return resres
            else
              Log.log.info("no new package")
            end
          end
          return nil
        end # dojob
      end # Main
    end # Plugin
  end # Cli
end # Asperalm
