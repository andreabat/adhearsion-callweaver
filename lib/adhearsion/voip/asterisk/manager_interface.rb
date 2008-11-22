require 'adhearsion/voip/asterisk/manager_interface/ami_lexer'

module Adhearsion
  module VoIP
    module Asterisk
      
      ##
      # Sorry, this AMI class has been deprecated. Please see http://docs.adhearsion.com/Asterisk_Manager_Interface for
      # documentation on the new way of handling AMI. This new version is much better and should not require an enormous
      # migration on your part.
      #
      class AMI
        def initialize
          raise "Sorry, this AMI class has been deprecated. Please see http://docs.adhearsion.com/Asterisk_Manager_Interface for documentation on the new way of handling AMI. This new version is much better and should not require an enormous migration on your part."
        end
      end
      
      module Manager
        
        ##
        # This class abstracts a connection to the Asterisk Manager Interface. Its purpose is, first and foremost, to make
        # the protocol consistent. Though the classes employed to assist this class (ManagerInterfaceAction,
        # ManagerInterfaceResponse, ManagerInterfaceError, etc.) are relatively user-friendly, they're designed to be a
        # building block on which to build higher-level abstractions of the Asterisk Manager Interface.
        #
        # For a higher-level abstraction of the Asterisk Manager Interface, see the SuperManager class.
        #
        class ManagerInterface
          
          class << self
            
            def connect(*args)
              returning new(*args) do |connection|
                connection.connect!
              end
            end
            
            def replies_with_action_id?(name, headers={})
              name = name.to_s.downcase
              # TODO: Expand this case statement
              case name
                when "queues", "iaxpeers"
                  false
                else
                  true
              end                
            end
            
            ##
            # When sending an action with "causal events" (i.e. events which must be collected to form a proper
            # response), AMI should send a particular event which instructs us that no more events will be sent.
            # This event is called the "causal event terminator".
            #
            # Note: you must supply both the name of the event and any headers because it's possible that some uses of an 
            # action (i.e. same name, different headers) have causal events while other uses don't.
            #
            # @param [String] name the name of the event
            # @param [Hash] the headers associated with this event
            # @return [String] the downcase()'d name of the event name for which to wait
            #
            def has_causal_events?(name, headers={})
              name = name.to_s.downcase
              case name
                when "queuestatus", "sippeers", "parkedcalls"
                  true
                else
                  false
              end
            end
            
            ##
            # Used to determine the event name for an action which has causal events.
            # 
            # @param [String] action_name
            # @return [String] The corresponding event name which signals the completion of the causal event sequence.
            # 
            def causal_event_terminator_name_for(action_name)
              return nil unless has_causal_events?(action_name)
               case action_name.downcase
                 when "queuestatus", 'parkedcalls'
                   action_name.downcase + "complete"
                 when "sippeers"
                   "peerlistcomplete"
               end
            end
            
          end
        
          DEFAULT_SETTINGS = {
            :host     => "localhost",
            :port     => 5038,
            :username => "admin",
            :password => "secret",
            :events   => true
          }.freeze unless defined? DEFAULT_SETTINGS
          
          attr_reader *DEFAULT_SETTINGS.keys
          
          ##
          # Creates a new Asterisk Manager Interface connection and exposes certain methods to control it. The constructor
          # takes named parameters as Symbols. Note: if the :events option is given, this library will establish a separate
          # socket for just events. Two sockets are used because some actions actually respond with events, making it very
          # complicated to differentiate between response-type events and normal events.
          #
          # @param [Hash] options Available options are :host, :port, :username, :password, and :events
          #
          def initialize(options={})
            options = parse_options options
            
            @host = options[:host]
            @username = options[:username] 
            @password = options[:password]
            @port     = options[:port]
            @events   = options[:events]
            
            @sent_messages = {}
            @sent_messages_lock = Mutex.new
            
            @actions_lexer = DelegatingAsteriskManagerInterfaceLexer.new self, \
                :message_received => :action_message_received,
                :error_received   => :action_error_received
            
            @write_queue = Queue.new
            
            if @events
              @events_lexer = DelegatingAsteriskManagerInterfaceLexer.new self, \
                  :message_received => :event_message_received,
                  :error_received   => :event_error_received 
            end
          end
          
          def action_message_received(message)
            if message.kind_of? Manager::ManagerInterfaceEvent
              # Trigger the return value of the waiting action id...
              corresponding_action   = @current_action_with_causal_events
              event_collection       = @event_collection_for_current_action
              
              if corresponding_action
                
                # If this is the meta-event which signals no more events will follow and the response is complete.
                if message.name.downcase == corresponding_action.causal_event_terminator_name
                  
                  # Wake up any Threads waiting
                  corresponding_action.future_resource.resource = event_collection.freeze
                  
                  @current_action_with_causal_events   = nil
                  @event_collection_for_current_action = nil
                  
                else
                  event_collection << message
                  # We have more causal events coming.
                end
              else
                ahn_log.ami.warn "Got an unexpected event on actions socket! This may be a bug! #{message.inspect}"
              end
              
            elsif message["ActionID"].nil?
              if @current_immediate_response_action
                @current_immediate_response_action.future_resource.resource = message
                @current_immediate_response_action = nil
              else
                ahn_log.ami.warn "Got an unexpected immediate response on actions socket! This may be a bug! #{message.inspect}"
              end
            else
              action_id = message["ActionID"]
              corresponding_action = data_for_message_received_with_action_id action_id
              if corresponding_action
                message.action = corresponding_action
                
                if corresponding_action.has_causal_events?
                  # By this point the write loop will already have started blocking by calling the response() method on the
                  # action. Because we must collect more events before we wake the write loop up again, let's create these
                  # instance variable which will needed when the subsequent causal events come in.
                  @current_action_with_causal_events   = corresponding_action
                  @event_collection_for_current_action = []
                else
                  # Wake any Threads waiting on the response.
                  corresponding_action.future_resource.resource = message
                end
              else
                ahn_log.ami.error "Received an AMI message with an unrecognized ActionID!! This may be an bug! #{message.inspect}"
              end
            end
          end
          
          def action_error_received(ami_error)
            action_id = ami_error["ActionID"]
            
            corresponding_action = data_for_message_received_with_action_id action_id

            if corresponding_action
              corresponding_action.future_resource.resource = ami_error
            else
              ahn_log.ami.error "Received an AMI error with an unrecognized ActionID!! This may be an bug! #{ami_error.inspect}"
            end
          end
          
          ##
          # Called only when this ManagerInterface is instantiated with events enabled.
          #
          def event_message_received(event)
            return if event.kind_of?(ManagerInterfaceResponse) && event["Message"] == "Authentication accepted"
            # TODO: convert the event name to a certain namespace.
            Events.trigger %w[asterisk manager_interface], event
          end
          
          def event_error_received(message)
            # Does this ever even occur?
            ahn_log.ami.error "Hmmm, got an error on the AMI events-only socket! This must be a bug! #{message.inspect}"
          end
          
          ##
          # Called when our Ragel parser encounters some unexpected syntax from Asterisk. Anytime this is called, it should
          # be considered a bug in Adhearsion. Note: this same method is called regardless of whether the syntax error
          # happened on the actions socket or on the events socket.
          #
          def syntax_error_encountered(ignored_chunk)
            ahn_log.ami.error "ADHEARSION'S AMI PARSER ENCOUNTERED A SYNTAX ERROR! " + 
                "PLEASE REPORT THIS ON http://bugs.adhearsion.com! OFFENDING TEXT:\n#{ignored_chunk.inspect}"
          end
          
          ##
          # Must be called after instantiation. Also see ManagerInterface::connect().
          #
          # @raise [AuthenticationFailedException] if username or password are rejected
          #
          def connect!
            establish_actions_connection
            establish_events_connection if @events
            self
          end
          
          def actions_connection_established
            @actions_state = :connected
            @actions_writer_thread = Thread.new(&method(:write_loop))
          end
          
          def actions_connection_disconnected
            @actions_state = :disconnected
          end
          
          def events_connection_established
            @events_state = :connected
          end
          
          def actions_connection_disconnected
            @events_state = :disconnected
          end
          
          def disconnect!
            # PSEUDO CODE
            # TODO: Go through all the waiting condition variables and raise an exception
            #@write_queue << :STOP!
            raise NotImplementedError
          end
        
          def dynamic
            # TODO: Return an object which responds to method_missing
          end
                    
          ##
          # Used to directly send a new action to Asterisk. Note: NEVER supply an ActionID; these are handled internally.
          #
          # @param [String, Symbol] action_name The name of the action (e.g. Originate)
          # @param [Hash] headers Other key/value pairs to send in this action. Note: don't provide an ActionID
          # @return [FutureResource] Call resource() on this object if you wish to access the response (optional). Note: if the response has not come in yet, your Thread will wait until it does.
          #
          def send_action_asynchronously(action_name, headers={})
            returning ManagerInterfaceAction.new(action_name, headers) do |action|
              @write_queue << action
            end
          end
          
          ##
          # Sends an action over the AMI connection and blocks your Thread until the response comes in. If there was an error
          # for some reason, the error will be raised as an ManagerInterfaceError.
          #
          # @param [String, Symbol] action_name The name of the action (e.g. Originate)
          # @param [Hash] headers Other key/value pairs to send in this action. Note: don't provide an ActionID
          # @raise [ManagerInterfaceError] When Asterisk can't execute this action, it sends back an Error which is converted into an ManagerInterfaceError object and raised. Access ManagerInterfaceError#message for the reported message from Asterisk.
          # @return [ManagerInterfaceResponse, ImmediateResponse] Contains the response from Asterisk and all headers
          #
          def send_action_synchronously(*args)
            returning send_action_asynchronously(*args).response do |response|
              raise response if response.kind_of?(ManagerInterfaceError)
            end
          end
          
          alias send_action send_action_synchronously
        
        
          #######                                              #######
          ###########                                      ###########
          ################# SOON-DEPRECATED COMMANDS ################# 
          ###########                                      ###########
          #######                                              #######
          
          def ping
            deprecation_warning
            send_action "Ping"
          end
          
          def deprecation_warning
            ahn_log.ami.deprecation.warn "The implementation of the ping, originate, introduce, hangup, call_into_context " +
                "and call_and_exec methods will soon be moved from this class to SuperManager. At the moment, the " +
                "SuperManager abstractions are not completed. Don't worry. The migration to SuperManager will be very easy."+
                " See http://docs.adhearsion.com/AMI for more information."
          end
          
          def originate(options={})
            deprecation_warning
            options = options.clone
            options[:callerid] = options.delete :caller_id if options.has_key? :caller_id
            send_action "Originate", options
          end

          # An introduction connects two endpoints together. The first argument is
          # the first person the PBX will call. When she's picked up, Asterisk will
          # play ringing while the second person is being dialed.
          #
          # The first argument is the person called first. Pass this as a canonical
          # IAX2/server/user type argument. Destination takes the same format, but
          # comma-separated Dial() arguments can be optionally passed after the
          # technology.
          #
          # TODO: Provide an example when this works.
          #
          def introduce(caller, callee, opts={})
            deprecation_warning
            dial_args  = callee
            dial_args += "|#{opts[:options]}" if opts[:options]
            call_and_exec caller, "Dial", :args => dial_args, :caller_id => opts[:caller_id]
          end

          def hangup(channel)
            deprecation_warning
            send_action "Hangup", :channel => channel
          end

          def call_and_exec(channel, app, opts={})
            deprecation_warning
            args = { :channel => channel, :application => app }
            args[:caller_id] = opts[:caller_id] if opts[:caller_id]
            args[:data] = opts[:args] if opts[:args]
            originate args
          end

          def call_into_context(channel, context, options={})
            deprecation_warning
            args = {:channel => channel, :context => context}
            args[:priority] = options[:priority] || 1
            args[:extension] = options[:extension] if options[:extension]
            args[:caller_id] = options[:caller_id] if options[:caller_id]
            if options[:variables] && options[:variables].kind_of?(Hash)
              args[:variable] = options[:variables].map {|pair| pair.join('=')}.join('|')
            end
            originate args
          end
          
          #######                                                  #######
          ###########                                          ###########
          ################# END SOON-DEPRECATED COMMANDS ################# 
          ###########                                          ###########
          #######                                                  #######

        
          protected
          
          def write_loop
            loop do
              next_action = @write_queue.shift
              return :stopped if next_action.equal? :STOP!
              
              if next_action.replies_with_action_id?
                register_action_with_metadata next_action
              else
                @current_immediate_response_action
              end
              
              ahn_log.ami.debug "Sending AMI action: #{"\n>>> " + next_action.to_s.gsub(/(\r\n)+/, "\n>>> ")}"
              @actions_connection.send_data next_action.to_s
              
              # If it's "causal event" or "immediate response" action, we must wait here until it's fully responded.
              next_action.response if next_action.has_causal_events? || !next_action.replies_with_action_id?
            end
          rescue => e
            p e
          end
          
          ##
          # When we send out an AMI action, we need to track the ActionID and have the other Thread handling the socket IO
          # notify the sending Thread that a response has been received. This method instantiates a new FutureResource and
          # keeps it around in a synchronized Hash for the IO-handling Thread to notify when a response with a matching
          # ActionID is seen again. See also data_for_message_received_with_action_id() which is how the IO-handling Thread
          # gets the metadata registered in the method back later.
          #
          # @param [ManagerInterfaceAction] action The ManagerInterfaceAction to send
          # @param [Hash] headers The other key/value pairs being sent with this message
          #
          def register_action_with_metadata(action)
            raise ArgumentError, "Must supply an action!" if action.nil?
            @sent_messages_lock.synchronize do
              @sent_messages[action.action_id] = action
            end
          end
          
          def data_for_message_received_with_action_id(action_id)
            @sent_messages_lock.synchronize do
              @sent_messages.delete action_id
            end
          end
          
          ##
          # Instantiates a new ManagerInterfaceActionsConnection and assigns it to @actions_connection.
          #
          # @return [EventSocket]
          #
          def establish_actions_connection
            @actions_connection = EventSocket.connect(@host, @port) do |handler|
              handler.receive_data { |data| @actions_lexer << data  }
              handler.connected    { actions_connection_established  }
              handler.disconnected { actions_connection_disconnected }
            end
            login_actions
          end
          
          ##
          # Instantiates a new ManagerInterfaceEventsConnection and assigns it to @events_connection.
          #
          # @return [EventSocket]
          #
          def establish_events_connection
            # Note: the @events_connection instance variable is set in login()
            @events_connection = EventSocket.connect(@host, @port) do |handler|
              handler.receive_data { |data| @events_lexer << data  }
              handler.connected    { events_connection_established  }
              handler.disconnected { events_connection_disconnected }
            end
            login_events
          end

          def login_actions
            action = send_action_asynchronously "Login", "Username" => @username, "Secret" => @password, "Events" => "Off"
            response = action.response
            if response.kind_of? ManagerInterfaceError
              raise AuthenticationFailedException, "Incorrect username and password! #{response.message}"
            else
              ahn_log.ami "Successful AMI connection into #{@username}@#{@host}"
              response
            end
          end
          
          ##
          # Since this method is always called after the login_actions method, an AuthenticationFailedException would have already
          # been raised if the username/password were off. Because this is the only action we ever need to send on this socket,
          # it goes straight to the EventSocket connection (bypassing the @write_queue).
          #
          def login_events
            login_action = ManagerInterfaceAction.new "Login", "Username" => @username, "Secret" => @password, "Events" => "On"
            @events_connection.send_data login_action.to_s
          end
          
          def parse_options(options)
            unrecognized_keys = options.keys.map { |key| key.to_sym } - DEFAULT_SETTINGS.keys
            if unrecognized_keys.any?
              raise ArgumentError, "Unrecognized named argument(s): #{unrecognized_keys.to_sentence}"
            end
            DEFAULT_SETTINGS.merge options
          end
          
          ##
          # Raised when calling ManagerInterface#connect!() and the server responds with an error after logging in.
          #
          class AuthenticationFailedException < Exception; end
          
          class NotConnectedError < Exception; end
          
          ##
          # Each time ManagerInterface#send_action is invoked, a new ManagerInterfaceAction is instantiated.
          #
          class ManagerInterfaceAction
            
            attr_reader :name, :headers, :future_resource, :action_id, :causal_event_terminator_name
            def initialize(name, headers={})
              @name      = name.to_s.downcase.freeze
              @headers   = headers.stringify_keys.freeze
              @action_id = new_action_id.freeze
              @future_resource = FutureResource.new
              @causal_event_terminator_name = ManagerInterface.causal_event_terminator_name_for name
            end
            
            ##
            # Used internally by ManagerInterface for the actions in AMI which break the protocol's definition and do not
            # reply with an ActionID.
            #
            def replies_with_action_id?
              ManagerInterface.replies_with_action_id?(@name, @headers)
            end
            
            ##
            # Some AMI actions effectively respond with many events which collectively constitute the actual response. These
            # Must be handled specially by the protocol parser, so this method helps inform the parser.
            #
            def has_causal_events?
              ManagerInterface.has_causal_events?(@name, @headers)
            end
            
            ##
            # Abstracts the generation of new ActionIDs. This could be implemented virutally any way, provided each
            # invocation returns something unique, so this will generate a GUID and return it.
            #
            # @return [String] characters in GUID format (e.g. "4C5F4E1C-A0F1-4D13-8751-C62F2F783062")
            #
            def new_action_id
              new_guid # Implemented in lib/adhearsion/foundation/pseudo_guid.rb
            end
            
            ##
            # Converts this action into a protocol-valid String, ready to be sent over a socket.
            #
            def to_s
              @textual_representation ||= (
                  "Action: #{@name}\r\nActionID: #{@action_id}\r\n" +
                  @headers.map { |(key,value)| "#{key}: #{value}" }.join("\r\n") +
                  (@headers.any? ? "\r\n\r\n" : "\r\n")
              )
            end
            
            ##
            # If the response has simply not been received yet from Asterisk, the calling Thread will block until it comes
            # in. Once the response comes in, subsequent calls immediately return a reference to the ManagerInterfaceResponse
            # object.
            #
            def response
              future_resource.resource
            end
                        
          end
        end
      end
    end
  end
end
