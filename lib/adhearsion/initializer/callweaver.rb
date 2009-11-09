require 'adhearsion/initializer/asterisk'
require 'adhearsion/voip/asterisk'
require 'adhearsion/voip/callweaver'
module Adhearsion
  class Initializer
    
    class CallweaverInitializer<AsteriskInitializer
      
      cattr_accessor :config, :ogi_server, :ami_client
      class << self
        
        def start
          self.config     = AHN_CONFIG.callweaver
          self.ogi_server = initialize_ogi
          self.ami_client = VoIP::Callweaver.manager_interface = initialize_ami if config.ami_enabled?
          join_server_thread_after_initialized
        end

        def stop
          agi_oerver.stop
          ami_client.disconnect! if ami_client
        end

        private

        def initialize_ogi
          VoIP::Callweaver::OGI::Server.new :host => config.listening_host,
                                          :port => config.listening_port
        end
        
        def initialize_ami
          options = ami_options
          start_ami_after_initialized
          returning VoIP::Callweaver::Manager::ManagerInterface.new(options) do
            class << VoIP::Callweaver
              if respond_to?(:manager_interface)
                ahn_log.warn "Callweaver.manager_interface already initialized?"
              else
                def manager_interface
                  # ahn_log.ami.warn "Warning! This Asterisk.manager_interface() notation is for Adhearsion version 0.8.0 only. Subsequent versions of Adhearsion will use a feature called SuperManager. Migrating to use SuperManager will be very simple. See http://docs.adhearsion.com/AMI for more information."
                  Adhearsion::Initializer::CallweaverInitializer.ami_client
                end
              end
            end
          end
        end
        
        def ami_options
          %w(host port username password events).inject({}) do |options, property|
            options[property.to_sym] = config.ami.send property
            options
          end
        end
        
        def join_server_thread_after_initialized
          Events.register_callback(:after_initialized) do
            begin
              ogi_server.start
            rescue => e
              ahn_log.fatal "Failed to start OGI server! #{e.inspect}"
              abort
            end
          end
          IMPORTANT_THREADS << ogi_server
        end
        
        def start_ami_after_initialized
          Events.register_callback(:after_initialized) do
            begin
              self.ami_client.connect!
            rescue Errno::ECONNREFUSED
              ahn_log.ami.error "Connection refused when connecting to AMI! Please check your configuration."
            rescue => e
              ahn_log.ami.error "Error connecting to AMI! #{e.inspect}"
            end
          end
        end

      end
    end
    
  end
end
