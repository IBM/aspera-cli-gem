#!/bin/echo this is a ruby class:
#
# FASP manager for Ruby
# Aspera 2016
# Laurent Martin
#
##############################################################################
require 'asperalm/fasp/manager'
require 'asperalm/fasp/error'
require 'asperalm/fasp/parameters'
require 'asperalm/fasp/installation'
require 'asperalm/fasp/resume_policy'
require 'asperalm/log'
require 'socket'
require 'timeout'
require 'singleton'
require 'securerandom'

module Asperalm
  module Fasp
    # default transfer username for access key based transfers
    ACCESS_KEY_TRANSFER_USER='xfer'
    # executes a local "ascp", equivalent of "Fasp Manager"
    class Local < Manager
      include Singleton
      attr_accessor :quiet
      # start FASP transfer based on transfer spec (hash table)
      # note that it returns upon completion only (blocking)
      # if the user wants to run in background, just spawn a thread
      # listener methods are called in context of calling thread
      def start_transfer(transfer_spec,options=nil)
        options||={}
        raise "option: must be hash (or nil)" unless options.is_a?(Hash)
        job_id=options[:job_id] || SecureRandom.uuid
        if transfer_spec['tags'].is_a?(Hash) and transfer_spec['tags']['aspera'].is_a?(Hash)
          # TODO: what is this for ? only on local ascp ?
          # NOTE: important: transfer id must be unique: generate random id
          # using a non unique id results in discard of tags in AoC, and a package is never finalized
          transfer_spec['tags']['aspera']['xfer_id']=SecureRandom.uuid
          Log.log.debug "xfer id=#{transfer_spec['xfer_id']}"
          # TODO: useful ? node only ?
          transfer_spec['tags']['aspera']['xfer_retry']=3600
        end
        Log.log.debug("ts=#{transfer_spec}")
        # suse bypass keys when authentication is token
        if transfer_spec['authentication'].eql?("token")
          # add Aspera private keys for web access, token based authorization
          transfer_spec['EX_ssh_key_paths'] = [ Installation.instance.path(:ssh_bypass_key_dsa), Installation.instance.path(:ssh_bypass_key_rsa) ]
          # mwouais...
          transfer_spec['drowssap_etomer'.reverse] = "%08x-%04x-%04x-%04x-%04x%08x" % "t1(\xBF;\xF3E\xB5\xAB\x14F\x02\xC6\x7F)P".unpack("NnnnnN")
        end
        # multi session is a node parameter, managed here in fasp manager
        multi_session=0
        fasp_port_base=33001
        if transfer_spec.has_key?('multi_session')
          multi_session=transfer_spec['multi_session'].to_i
          transfer_spec.delete('multi_session')
          # TODO: check if changing fasp port is really necessary
          if transfer_spec.has_key?('fasp_port')
            fasp_port_base=transfer_spec['fasp_port']
            transfer_spec.delete('fasp_port')
          end
        end

        # compute known args
        env_args=Parameters.ts_to_env_args(transfer_spec)

        # add fallback cert and key as arguments if needed
        if ['1','force'].include?(transfer_spec['http_fallback'])
          env_args[:args].unshift('-Y',Installation.instance.path(:fallback_key))
          env_args[:args].unshift('-I',Installation.instance.path(:fallback_cert))
        end

        env_args[:args].unshift('-q') if @quiet

        # transfer job can be multi session
        xfer_job={
          :id            => job_id,
          :sessions      => []
        }

        # generic session information
        session={
          :state    => :initial, # :initial, :started, :success, :failed
          :env_args => env_args,
          :resumer  => ResumePolicy.instance,
          :options  => options
        }

        Log.log.debug("starting session thread(s)")
        if multi_session.eql?(0)
          session[:thread] = Thread.new(session) {|s|transfer_thread_entry(s)}
          xfer_job[:sessions].push(session)
        else
          1.upto(multi_session) do |i|
            # do deep copy (each thread has its own copy because it is modified here below and in thread)
            this_session=Marshal.load(Marshal.dump(session))
            this_session[:env_args][:args].unshift("-C#{i}:#{multi_session}")
            # check if this is necessary ? should be handled by server, this is in man page
            this_session[:env_args][:args].unshift("-O","#{fasp_port_base+i-1}")
            this_session[:thread] = Thread.new(this_session) {|s|transfer_thread_entry(s)}
            xfer_job[:sessions].push(this_session)
          end
        end
        Log.log.debug("started session thread(s)")

        # add job to list of jobs
        @jobs[job_id]=xfer_job

        Log.log.debug("jobs: #{@jobs.keys.count}")
        return job_id
      end # start_transfer

      # terminates monitor thread
      def shutdown(wait_for_sessions=false)
        Log.log.debug("fasp local shutdown")
        if wait_for_sessions
          Log.log.debug("wait_for_sessions: #{@jobs.values.inject(0){|m,j|m+j[:sessions].count}}")
          @mutex.synchronize do
            loop do
              running=0
              @jobs.values.each do |job|
                job[:sessions].each do |session|
                  case session[:state]
                  when :failed; raise StandardError,"at least one session failed: #{session[:error]}"
                  when :success # ignore
                  else running+=1
                  end
                end
              end
              break if running.eql?(0)
              Log.log.debug("wait for completed: running: #{running}")
              # wait for session termination
              @cond_var.wait(@mutex)
            end # loop
          end # mutex
        end
        Log.log.debug("send signal to monitor")
        # tell monitor to stop
        @mutex.synchronize do
          @monitor_stop=true
          @cond_var.broadcast
        end
        # wait for thread termination
        @monitor_thread.join
        @monitor_thread=nil
        Log.log.debug("joined monitor")
      end

      # This is the low level method to start FASP
      # currently, relies on command line arguments
      # start ascp with management port.
      # raises FaspError on error
      # if there is a thread info: set and broadcast session id
      # @param env_args a hash containing :args :env :ascp_version
      def start_transfer_with_args_env(env_args,session=nil)
        begin
          Log.log.debug("env_args=#{env_args.inspect}")
          ascp_path=Fasp::Installation.instance.path(env_args[:ascp_version])
          raise Fasp::Error.new("no such file: #{ascp_path}") unless File.exist?(ascp_path)
          ascp_pid=nil
          ascp_arguments=env_args[:args].clone
          # open random local TCP port listening
          mgt_sock = TCPServer.new('127.0.0.1',0 )
          # add management port
          ascp_arguments.unshift('-M', mgt_sock.addr[1].to_s)
          # start ascp in sub process
          Log.log.debug "execute: #{env_args[:env].map{|k,v| "#{k}=\"#{v}\""}.join(' ')} \"#{ascp_path}\" \"#{ascp_arguments.join('" "')}\""
          # start process
          ascp_pid = Process.spawn(env_args[:env],[ascp_path,ascp_path],*ascp_arguments)
          # in parent, wait for connection to socket max 3 seconds
          Log.log.debug "before accept for pid (#{ascp_pid})"
          ascp_mgt_io=nil
          Timeout.timeout( 3 ) do
            ascp_mgt_io = mgt_sock.accept
          end
          Log.log.debug "after accept (#{ascp_mgt_io})"

          unless session.nil?
            @mutex.synchronize do
              session[:io]=ascp_mgt_io
              @cond_var.broadcast
            end
          end
          Log.log.debug("->>#{}")
          # exact text for event, with \n
          current_event_text=''
          # parsed event (hash)
          current_event_data=nil

          # this is the last full status
          last_status_event=nil

          # read management port
          loop do
            # TODO: timeout here ?
            line = ascp_mgt_io.gets
            # nil when ascp process exits
            break if line.nil?
            current_event_text=current_event_text+line
            line.chomp!
            Log.log.debug("line=[#{line}]")
            case line
            when 'FASPMGR 2'
              # begin event
              current_event_data = Hash.new
              current_event_text = ''
            when /^([^:]+): (.*)$/
              # event field
              current_event_data[$1] = $2
            when ''
              # end event
              raise "unexpected empty line" if current_event_data.nil?
              notify_listeners(current_event_text,current_event_data)
              # TODO: check if this is always the last event
              case current_event_data['Type']
              when 'DONE','ERROR'
                last_status_event = current_event_data
              when 'INIT'
                unless session.nil?
                  @mutex.synchronize do
                    session[:state]=:started
                    session[:id]=current_event_data['SessionId']
                    Log.log.debug("session id: #{session[:id]}")
                    @cond_var.broadcast
                  end
                end
              end # event type
            else
              raise "unexpected line:[#{line}]"
            end # case
          end # loop
          # check that last status was received before process exit
          raise "INTERNAL: nil last status" if last_status_event.nil?
          case last_status_event['Type']
          when 'DONE'
            return
          when 'ERROR'
            e=Fasp::Error.new(last_status_event['Description'],last_status_event['Code'].to_i)
            Log.log.error("code: #{e.err_code}") if e.respond_to?(:err_code)
            if e.message  =~ /bearer token/i
              Log.log.error("need to regenrate token".red)
              if !session.nil? and session[:options].is_a?(Hash) and session[:options].has_key?(:regenerate_token)
                # regenerate token here, expired, or error on it
                env_args[:env]['ASPERA_SCP_TOKEN']=session[:options][:regenerate_token].call(true)
              end
            end
            raise e
          else
            raise "INTERNAL ERROR: unexpected last event"
          end
        rescue SystemCallError => e
          # Process.spawn
          raise Fasp::Error.new(e.message)
        rescue Timeout::Error => e
          raise Fasp::Error.new('timeout waiting mgt port connect')
        rescue Interrupt => e
          raise Fasp::Error.new('transfer interrupted by user')
        ensure
          # ensure there is no ascp left running
          unless ascp_pid.nil?
            begin
              Process.kill('INT',ascp_pid)
            rescue
            end
            # avoid zombie
            Process.wait(ascp_pid)
            ascp_pid=nil
            session.delete(:io)
          end
        end # begin-ensure
      end # start_transfer_with_args_env

      # send command on mgt port, examples:
      # {'type'=>'START','source'=>_path_,'destination'=>_path_}
      # {'type'=>'DONE'}
      def send_command(job_id,session_index,data)
        @mutex.synchronize do
          job=@jobs[job_id]
          raise "no such job" if job.nil?
          session=job[:sessions][session_index]
          raise "no such session" if session.nil?
          Log.log.debug("command: #{data}")
          command=data.
          keys.
          map{|k|"#{k.capitalize}: #{data[k]}"}.
          unshift('FASPMGR 2').
          push('','').
          join("\n")
          session[:io].puts(command)
        end
      end

      private

      def initialize
        super
        # set to true to skip ascp progress bar display (basically: ascp's option -q)
        @quiet=false
        # shared data between transfer threads and others: protected by mutex, CV on change
        @jobs={}
        # mutex protects jobs data
        @mutex=Mutex.new
        # cond var is waited or broadcast on jobs data change
        @cond_var=ConditionVariable.new
        # must be set before starting monitor, set to false to stop thread. also shared and protected by mutex
        @monitor_stop=false
        @monitor_thread=Thread.new{monitor_thread_entry}
      end

      # transfer thread entry
      # implements resumable transfer
      # TODO: extract resume algorithm in a specific object
      def transfer_thread_entry(session)
        begin
          # set name for logging
          Thread.current[:name]="transfer"
          # update state once in thread
          session[:state]=:started
          Log.log.debug("ENTER (#{Thread.current[:name]})")
          # start transfer with selected resumer policy
          session[:resumer].process do
            start_transfer_with_args_env(session[:env_args],session)
          end
          Log.log.debug('transfer ok'.bg_green)
          session[:state]=:success
        rescue => e
          session[:state]=:failed
          session[:error]=e
          Log.log.error(e.message)
        ensure
          @mutex.synchronize do
            # ensure id is set to unblock start procedure
            session[:id]||=nil
            @cond_var.broadcast
          end
        end
        Log.log.debug("EXIT (#{Thread.current[:name]})")
      end

      # main thread method for monitor
      # currently: just joins started threads
      def monitor_thread_entry
        Thread.current[:name]="monitor"
        @mutex.synchronize do
          until @monitor_stop do
            # wait for session termination
            @cond_var.wait(@mutex)
            @jobs.values do |job|
              job[:sessions].each do |session|
                session[:thread].join if [:success,:failed].include?(session[:state])
              end # sessions
            end # jobs
          end # monitor run
        end # sync
        Log.log.debug("EXIT (#{Thread.current[:name]})")
      end # monitor_thread_entry
    end # Local
  end
end
