require 'asperalm/cli/main'
require 'asperalm/cli/plugins/node'
require 'asperalm/cli/plugin'
require 'asperalm/oauth'
require 'asperalm/files_api'
require 'securerandom'

module Asperalm
  module Cli
    module Plugins
      class Files < Plugin
        # returns a node API for access key
        # no scope: requires secret
        # if secret present: use it
        def get_files_node_api(node_info,node_scope=nil)
          # if no scope, or secret provided on command line ...
          if node_scope.nil? or !Main.tool.options.get_option(:secret).nil?
            return Rest.new(node_info['url'],{:auth=>{:type=>:basic,:username=>node_info['access_key'], :password=>Main.tool.options.get_option_mandatory(:secret)},:headers=>{'X-Aspera-AccessKey'=>node_info['access_key']}})
          end
          Log.log.warn("ignoring secret, using bearer token") if !Main.tool.options.get_option(:secret).nil?
          return Rest.new(node_info['url'],{:auth=>{:type=>:oauth2,:obj=>@api_files_oauth,:scope=>FilesApi.node_scope(node_info['access_key'],node_scope)},:headers=>{'X-Aspera-AccessKey'=>node_info['access_key']}})
        end

        # returns node information (returned by API) and file id, from a "/" based path
        # supports links to secondary nodes
        # input: root node and file id, and array for path
        # output: file_id and node_info  for the given path
        def find_nodeinfo_and_fileid ( top_node_id, top_file_id, element_path_string )
          Log.log.debug "find_nodeinfo_and_fileid: nodeid=#{top_node_id}, #{top_file_id}, path=#{element_path_string}"
          
          # initialize loop elements
          current_path_elements=element_path_string.split(PATH_SEPARATOR).select{|i| !i.empty?}
          current_node_info=@api_files_user.read("nodes/#{top_node_id}")[:data]
          current_file_id = top_file_id
          current_file_info = nil
 
          while !current_path_elements.empty? do
            current_element_name = current_path_elements.shift
            Log.log.debug "searching #{current_element_name}".bg_green
            # get API if changed
            current_node_api=get_files_node_api(current_node_info,FilesApi::SCOPE_NODE_USER) if current_node_api.nil?
            # get folder content
            folder_contents = current_node_api.read("files/#{current_file_id}/files")
            Log.log.debug "folder_contents: #{folder_contents}"
            matching_folders = folder_contents[:data].select { |i| i['name'].eql?(current_element_name)}
            #Log.log.debug "matching_folders: #{matching_folders}"
            raise CliBadArgument, "no such folder: #{current_element_name} in #{folder_contents[:data].map { |i| i['name']}}" if matching_folders.empty?
            current_file_info = matching_folders.first
            # process type of file
            case current_file_info['type']
            when 'file'
              current_file_id=current_file_info["id"]
              # a file shall be terminal
              if !current_path_elements.empty? then
                raise CliBadArgument, "#{current_element_name} is a file, expecting folder to find: #{current_path_elements}"
              end
            when 'link'
              current_node_info=@api_files_user.read("nodes/#{current_file_info['target_node_id']}")[:data]
              current_file_id=current_file_info["target_id"]
              current_node_api=nil
            when 'folder'
              current_file_id=current_file_info["id"]
            else
              Log.log.warn "unknown element type: #{current_file_info['type']}"
            end
          end
          Log.log.info("node_info,file_id=#{current_node_info},#{current_file_id}")
          return current_node_info,current_file_id
        end

        # generate a transfer spec from node information and file id
        # NOTE: important: transfer id must be unique: generate random id (using a non unique id results in discard of tags, and package is not finalized)
        def info_to_tspec(direction,node_info,file_id)
          return {
            'direction'        => direction,
            'remote_user'      => 'xfer',
            'remote_host'      => node_info['host'],
            "fasp_port"        => 33001, # TODO: always the case ?
            "ssh_port"         => 33001, # TODO: always the case ?
            'token'            => @api_files_oauth.get_authorization(FilesApi.node_scope(node_info['access_key'],FilesApi::SCOPE_NODE_USER)),
            'tags'             => { "aspera" => { "node" => { "access_key" => node_info['access_key'], "file_id" => file_id }, "xfer_id" => SecureRandom.uuid, "xfer_retry" => 3600 } } }
        end

        def declare_options
          Main.tool.options.set_option(:download_mode,:fasp)
          Main.tool.options.add_opt_list(:download_mode,[:fasp, :node_http ],"download mode",'--download=TYPE')
          Main.tool.options.add_opt_list(:auth,Oauth.auth_types,"type of authentication",'-tTYPE','--auth=TYPE')
          Main.tool.options.add_opt_simple(:url,"-wURI", "--url=URI","URL of application, e.g. http://org.asperafiles.com")
          Main.tool.options.add_opt_simple(:username,"-uSTRING", "--username=STRING","username to log in")
          Main.tool.options.add_opt_simple(:password,"-pSTRING", "--password=STRING","password")
          Main.tool.options.add_opt_simple(:private_key,"-kSTRING", "--private-key=STRING","RSA private key for JWT (@ for ext. file)")
          Main.tool.options.add_opt_simple(:workspace,"--workspace=STRING","name of workspace")
          Main.tool.options.add_opt_simple(:recipient,"--recipient=STRING","package recipient")
          Main.tool.options.add_opt_simple(:title,"--title=STRING","package title")
          Main.tool.options.add_opt_simple(:note,"--note=STRING","package note")
          Main.tool.options.add_opt_simple(:secret,"--secret=STRING","access key secret for node")
        end

        PATH_SEPARATOR='/'

        def execute_node_action(home_node_id,home_file_id)
          command_repo=Main.tool.options.get_next_arg_from_list('command',Node.simple_actions.clone.concat([ :browse, :upload, :download, :file ]))
          case command_repo
          when *Node.simple_actions
            # TODO: shall we support all methods here ? what if there is a link ?
            node_info=@api_files_user.read("nodes/#{home_node_id}")[:data]
            node_api=get_files_node_api(node_info,FilesApi::SCOPE_NODE_USER)
            return Node.execute_common(command_repo,node_api)
          when :file
            fileid=Main.tool.options.get_next_arg_value("file id")
            node_info,file_id = find_nodeinfo_and_fileid(home_node_id,fileid,"")
            node_api=get_files_node_api(node_info,FilesApi::SCOPE_NODE_USER)
            items=node_api.read("files/#{file_id}")[:data]
            return {:data=>items,:type=>:key_val_list}
          when :browse
            thepath=Main.tool.options.get_next_arg_value("path")
            node_info,file_id = find_nodeinfo_and_fileid(home_node_id,home_file_id,thepath)
            node_api=get_files_node_api(node_info,FilesApi::SCOPE_NODE_USER)
            items=node_api.read("files/#{file_id}/files")[:data]
            return {:data=>items,:type=>:hash_array,:fields=>['name','type','recursive_size','size','modified_time','access_level']}
          when :upload
            filelist = Main.tool.options.get_remaining_arguments("file list,destination")
            Log.log.debug("file list=#{filelist}")
            raise CliBadArgument,"Missing source(s) and destination" if filelist.length < 2
            destination_folder=filelist.pop
            node_info,file_id = find_nodeinfo_and_fileid(home_node_id,home_file_id,destination_folder)
            tspec=info_to_tspec("send",node_info,file_id)
            tspec['tags']["aspera"]["files"]={}
            tspec['paths']=filelist.map { |i| {'source'=>i} }
            tspec['destination_root']="/"
            return Main.tool.start_transfer(tspec)
          when :download
            source_file=Main.tool.options.get_next_arg_value('source')
            destination_folder=Main.tool.options.get_next_arg_value('destination')
            case Main.tool.options.get_option_mandatory(:download_mode)
            when :fasp
              file_path = source_file.split(PATH_SEPARATOR)
              file_name = file_path.pop
              node_info,file_id = find_nodeinfo_and_fileid(home_node_id,home_file_id,file_path.join(PATH_SEPARATOR))
              tspec=info_to_tspec('receive',node_info,file_id)
              tspec['tags']["aspera"]["files"]={}
              tspec['paths']=[{'source'=>file_name}]
              tspec['destination_root']=destination_folder
              return Main.tool.start_transfer(tspec)
            when :node_http
              file_path = source_file.split(PATH_SEPARATOR)
              file_name = file_path.last
              node_info,file_id = find_nodeinfo_and_fileid(home_node_id,home_file_id,source_file)
              node_api=get_files_node_api(node_info,FilesApi::SCOPE_NODE_USER)
              download_data=node_api.call({:operation=>'GET',:subpath=>"files/#{file_id}/content",:save_to_file=>File.join(destination_folder,file_name)})
              return {:data=>"downloaded: #{file_name}",:type => :status}
            end
          end
        end

        def action_list; [ :package, :repo, :faspexgw, :admin];end

        def execute_action
          command=Main.tool.options.get_next_arg_from_list('command',action_list)

          # get parameters
          instance_fqdn=URI.parse(Main.tool.options.get_option_mandatory(:url)).host
          organization,instance_domain=instance_fqdn.split('.',2)
          files_api_base_url=FilesApi.baseurl(instance_domain)

          Log.log.debug("instance_fqdn=#{instance_fqdn}")
          Log.log.debug("instance_domain=#{instance_domain}")
          Log.log.debug("organization=#{organization}")

          auth_data={
            :persist_folder => Main.tool.config_folder,
            :type=>Main.tool.options.get_option_mandatory(:auth),
            :client_id =>Main.tool.options.get_option_mandatory(:client_id),
            :client_secret=>Main.tool.options.get_option_mandatory(:client_secret)
          }

          case auth_data[:type]
          when :basic
            auth_data[:username]=Main.tool.options.get_option_mandatory(:username)
            auth_data[:password]=Main.tool.options.get_option_mandatory(:password)
          when :web
            auth_data[:redirect_uri]=Main.tool.options.get_option_mandatory(:redirect_uri)
            Log.log.info("redirect_uri=#{auth_data[:redirect_uri]}")
          when :jwt
            auth_data[:private_key]=OpenSSL::PKey::RSA.new(Main.tool.options.get_option_mandatory(:private_key))
            auth_data[:subject]=Main.tool.options.get_option_mandatory(:username)
            Log.log.info("private_key=#{auth_data[:private_key]}")
            Log.log.info("subject=#{auth_data[:subject]}")
          when :url_token
            auth_data[:url_token]=Main.tool.options.get_option_mandatory(:url_token)
          else
            raise "unknown auth type: #{auth_data[:type]}"
          end

          # auth API
          @api_files_oauth=Oauth.new(files_api_base_url,organization,auth_data)

          # create object for REST calls to Files with scope "user:all"
          @api_files_user=Rest.new(files_api_base_url,{:auth=>{:type=>:oauth2,:obj=>@api_files_oauth,:scope=>FilesApi::SCOPE_FILES_USER}})

          # get our user's default information
          self_data=@api_files_user.read("self")[:data]

          ws_name=Main.tool.options.get_option(:workspace)
          if ws_name.nil?
            # get default workspace
            workspace_id=self_data['default_workspace_id']
            workspace_data=@api_files_user.read("workspaces/#{workspace_id}")[:data]
          else
            # lookup another workspace
            wss=@api_files_user.read("workspaces",{'q'=>ws_name})[:data]
            wss=wss.select { |i| i['name'].eql?(ws_name) }
            case wss.length
            when 0
              raise CliBadArgument,"no such workspace: #{ws_name}"
            when 1
              workspace_data=wss[0]
              workspace_id=workspace_data['id']
            else
              raise "unexpected case"
            end
          end

          if Main.tool.options.get_option(:format).eql?(:formatted) and !command.eql?(:admin)
            deflt=""
            deflt=" (default)" if (workspace_id == self_data['default_workspace_id'])
            puts "Current Workspace: #{workspace_data['name'].red}#{deflt}"
          end

          # display name of default workspace
          Log.log.info("current workspace is "+workspace_data['name'].red)

          case command
          when :package
            command_pkg=Main.tool.options.get_next_arg_from_list('command',[ :send, :recv, :list ])
            case command_pkg
            when :send
              # list of files to include in package
              filelist = Main.tool.options.get_remaining_arguments("file list")

              # lookup users
              recipient_data=Main.tool.options.get_option_mandatory(:recipient).split(',').map { |recipient|
                user_lookup=@api_files_user.read("contacts",{'current_workspace_id'=>workspace_id,'q'=>recipient})[:data]
                raise CliBadArgument,"no such user: #{recipient}" unless !user_lookup.nil? and user_lookup.length == 1
                recipient_user_id=user_lookup.first
                {"id"=>recipient_user_id['source_id'],"type"=>recipient_user_id['source_type']}
              }

              #  create a new package with one file
              the_package=@api_files_user.create("packages",{"workspace_id"=>workspace_id,"name"=>Main.tool.options.get_option_mandatory(:title),"file_names"=>filelist,"note"=>Main.tool.options.get_option_mandatory(:note),"recipients"=>recipient_data})[:data]

              #  get node information for the node on which package must be created
              node_info=@api_files_user.read("nodes/#{the_package['node_id']}")[:data]

              # tell Files what to expect in package: 1 transfer (can also be done after transfer)
              resp=@api_files_user.update("packages/#{the_package['id']}",{"sent"=>true,"transfers_expected"=>1})[:data]

              tspec=info_to_tspec("send",node_info,the_package['contents_file_id'])
              tspec['tags']["aspera"]["files"]={"package_id" => the_package['id'], "package_operation" => "upload"}
              tspec['paths']=filelist.map { |i| {'source'=>i} }
              tspec['destination_root']="/"
              return Main.tool.start_transfer(tspec)
            when :recv
              package_id=Main.tool.options.get_next_arg_value('package ID')
              the_package=@api_files_user.read("packages/#{package_id}")[:data]
              node_info=@api_files_user.read("nodes/#{the_package['node_id']}")[:data]
              tspec=info_to_tspec("receive",node_info,the_package['contents_file_id'])
              tspec['tags']["aspera"]["files"]={"package_id" => the_package['id'], "package_operation" => "download"}
              tspec['paths']=[{'source'=>'.'}]
              tspec['destination_root']='.' # TODO:param?
              return Main.tool.start_transfer(tspec)
            when :list
              # list all packages ('page'=>1,'per_page'=>10,)'sort'=>'-sent_at',
              packages=@api_files_user.read("packages",{'archived'=>false,'exclude_dropbox_packages'=>true,'has_content'=>true,'received'=>true,'workspace_id'=>workspace_id})[:data]
              return {:data=>packages,:fields=>['id','name','bytes_transferred'],:type=>:hash_array}
            end
          when :repo
            home_node_id=workspace_data['home_node_id']
            home_file_id=workspace_data['home_file_id']
            return execute_node_action(home_node_id,home_file_id)
          when :faspexgw
            require 'asperalm/faspex_gw'
            FaspexGW.start_server(@api_files_user,workspace_id)
          when :admin
            api_files_admin=Rest.new(files_api_base_url,{:auth=>{:type=>:oauth2,:obj=>@api_files_oauth,:scope=>FilesApi::SCOPE_FILES_ADMIN}})
            command_admin=Main.tool.options.get_next_arg_from_list('command',[ :resource, :events, :set_client_key, :usage_reports, :search_nodes  ])
            case command_admin
            when :search_nodes
              ak=Main.tool.options.get_next_arg_value('access_key')
              nodes=api_files_admin.read("search_nodes",{'q'=>'access_key:"'+ak+'"'})[:data]
              return {:data=>nodes,:type=>:other_struct}
            when :events
              # page=1&per_page=10&q=type:(file_upload+OR+file_delete+OR+file_download+OR+file_rename+OR+folder_create+OR+folder_delete+OR+folder_share+OR+folder_share_via_public_link)&sort=-date
              #events=api_files_admin.read('events',{'q'=>'type:(file_upload OR file_download)'})[:data]
              #Log.log.info "events=#{JSON.generate(events)}"
              node_info=@api_files_user.read("nodes/#{workspace_data['home_node_id']}")[:data]
              # get access to node API, note the additional header
              api_node=get_files_node_api(node_info,FilesApi::SCOPE_NODE_USER)
              # can add filters: tag=aspera.files.package_id%3DLA8OU3p8w
              #'tag'=>'aspera.files.package_id%3DJvbl0w-5A'
              # filter= 'id', 'short_summary', or 'summary'
              # count=nnn
              # tag=x.y.z%3Dvalue
              # iteration_token=nnn
              # active_only=true|false
              events=api_node.read("ops/transfers",{'count'=>100,'filter'=>'summary','active_only'=>'true'})[:data]
              return {:data=>events,:fields=>['id','status'],:type=>:hash_array}
              #transfers=api_node.make_request_ex({:operation=>'GET',:subpath=>'ops/transfers',:args=>{'count'=>25,'filter'=>'id'}})
              #transfers=api_node.read("events") # after_time=2016-05-01T23:53:09Z
            when :set_client_key
              the_client_id=Main.tool.options.get_next_arg_value('client_id')
              the_private_key=Main.tool.options.get_next_arg_value('private_key')
              res=api_files_admin.update("clients/#{the_client_id}",{:jwt_grant_enabled=>true, :public_key=>OpenSSL::PKey::RSA.new(the_private_key).public_key.to_s})
              return Main.result_success
            when :resource
              resource=Main.tool.options.get_next_arg_from_list('resource',[:user,:group,:client,:contact,:dropbox,:node,:operation,:package,:saml_configuration, :workspace])
              resources=resource.to_s+(resource.eql?(:dropbox) ? 'es' : 's')
              #:messages:organizations:url_tokens,:usage_reports:workspaces
              operations=[:list,:id]
              #command=Main.tool.options.get_next_arg_value('op_or_id')
              command=Main.tool.options.get_next_arg_from_list('command',operations)
              case command
              when :list
                default_fields=['id','name']
                case resource
                when :node; default_fields.push('host','access_key')
                when :operation; default_fields=nil
                when :contact; default_fields=["email","name","source_id","source_type"]
                end
                return {:data=>api_files_admin.read(resources)[:data],:fields=>default_fields,:type=>:hash_array}
              when :id
                #raise RuntimeError, "unexpected resource type: #{resource}, only 'node' for actions" if !resource.eql?(:node)
                res_id=Main.tool.options.get_next_arg_value('node id')
                res_data=@api_files_user.read("#{resources}/#{res_id}")[:data]
                case resource
                when :node
                  api_node=get_files_node_api(res_data)
                  ak_data=api_node.call({:operation=>'GET',:subpath=>"access_keys/#{res_data['access_key']}",:headers=>{'Accept'=>'application/json'}})[:data]
                  return execute_node_action(res_id,ak_data['root_file_id'])
                else
                  return { :data => res_data, :type=>:key_val_list }
                end
              end #op_or_id
            when :usage_reports
              return {:data=>api_files_admin.read("usage_reports",{:workspace_id=>workspace_id})[:data],:type=>:hash_array}
            end
          else
            raise RuntimeError, "unexpected value: #{command}"
          end # action
        end
      end # Files
    end # Plugins
  end # Cli
end # Asperalm
