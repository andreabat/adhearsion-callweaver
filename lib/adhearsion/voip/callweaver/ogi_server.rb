require 'gserver'
module Adhearsion
  module VoIP
    module Callweaver
      module OGI
        class Server  < Adhearsion::VoIP::Asterisk::AGI::Server
        
        	class RubyServer <  Adhearsion::VoIP::Asterisk::AGI::Server::RubyServer
        	
        	  
        	
        	 	 
             	end	 
             
             
        	
        	
       	   DEFAULT_OPTIONS = { :server_class => Adhearsion::VoIP::Callweaver::OGI::Server::RubyServer, :port => 4573,:platform=>:callweaver, :host => "0.0.0.0" }
          attr_reader :host, :port, :server_class, :server,:platform

           def initialize(options = {})
            options                     = DEFAULT_OPTIONS.merge options
            @host, @port, @server_class,@platform = options.values_at(:host, :port, :server_class,:platform)
            @server                     = server_class.new(port, host,platform)
           
          end
        	
        end 
      end
    end
  end
end
