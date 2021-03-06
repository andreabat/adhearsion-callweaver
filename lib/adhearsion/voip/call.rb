require 'uri'
#TODO Some of this is asterisk-specific
module Adhearsion
  class << self
    def active_calls
      @calls ||= Calls.new
    end
  
    def receive_call_from(io, &block)
      active_calls << (call = Call.receive_from(io, &block))
     
      call
    end
    
    def remove_inactive_call(call)
      active_calls.remove_inactive_call(call)
    end
  end
  
  class Hangup < Exception
    # At the moment, we'll just use this to end a call-handling Thread.
  end
  
  ##
  # This manages the list of calls the Adhearsion service receives
  class Calls
    def initialize
      @semaphore = Monitor.new
      @calls     = {}
    end
    
    def <<(call)
      atomically do
        calls[call.unique_identifier] = call
      end
    end
    
    def any?
      atomically do
        !calls.empty?
      end
    end
    
    def size
      atomically do
        calls.size
      end
    end
    
    def remove_inactive_call(call)
      atomically do
        calls.delete call.unique_identifier
      end
    end
    
    # Searches all active calls by their unique_identifier. See Call#unique_identifier.
    def find(id)
      atomically do
        return calls[id]
      end
    end
    
    def clear!
      atomically do
        calls.clear
      end
    end
    
    def with_tag(tag)
      atomically do
        calls.inject(Array.new) do |calls_with_tag,(key,call)|
          call.tagged_with?(tag) ? calls_with_tag << call : calls_with_tag
        end
      end
    end
    
    def to_a
      calls.values
    end
    
    private
      attr_reader :semaphore, :calls
      
      def atomically(&block)
        semaphore.synchronize(&block)
      end
      
  end
  
  class UselessCallException < Exception; end
  
  class MetaAgiCallException < Exception
    attr_reader :call
    def initialize(call)
      super()
      @call = call
    end
  end
  
  class FailedExtensionCallException < MetaAgiCallException; end
  
  class HungupExtensionCallException < MetaAgiCallException; end
  
  ##
  # Encapsulates call-related data and behavior.
  # For example, variables passed in on call initiation are
  # accessible here as attributes    
  class Call
    
    # This is basically a translation of ast_channel_reason2str() from main/channel.c and
    # ast_control_frame_type in include/asterisk/frame.h in the Asterisk source code. When
    # Asterisk jumps to the 'failed' extension, it sets a REASON channel variable to a number.
    # The indexes of these symbols represent the possible numbers REASON could be.
    ASTERISK_FRAME_STATES = [
      :failure,     # "Call Failure (not BUSY, and not NO_ANSWER, maybe Circuit busy or down?)"
      :hangup,      # Other end has hungup
      :ring,        # Local ring
      :ringing,     # Remote end is ringing
      :answer,      # Remote end has answered
      :busy,        # Remote end is busy
      :takeoffhook, # Make it go off hook
      :offhook,     # Line is off hook
      :congestion,  # Congestion (circuits busy)
      :flash,       # Flash hook
      :wink,        # Wink
      :option,      # Set a low-level option
      :radio_key,   # Key Radio
      :radio_unkey, # Un-Key Radio
      :progress,    # Indicate PROGRESS
      :proceeding,  # Indicate CALL PROCEEDING
      :hold,        # Indicate call is placed on hold
      :unhold,      # Indicate call is left from hold
      :vidupdate    # Indicate video frame update
    ]
    
    
    class << self
      ##
      # The primary public interface for creating a Call instance.
      # Given an IO (probably a socket accepted from an Asterisk service),
      # creates a Call instance which encapsulates everything we know about that call.
      def receive_from(io, &block)
        returning new(io, variable_parser_for(io).variables) do |call|
        p "IN CALL"
        p block
          block.call(call) if block
        end
      end
    
      private
      def variable_parser_for(io)
        Variables::Parser.parse(io)
      end
      
    end
    
    attr_accessor :io, :type, :variables, :originating_voip_platform, :inbox
    def initialize(io, variables)
      @io, @variables = io, variables.symbolize_keys
      check_if_valid_call
      define_variable_accessors
      set_originating_voip_platform!
      @tag_mutex = Mutex.new
      @tags = []
    end

    def tags
      @tag_mutex.synchronize do
        return @tags.clone
      end
    end

    def tag(symbol)
      raise ArgumentError, "tag must be a Symbol" unless symbol.is_a? Symbol
      @tag_mutex.synchronize do
        @tags << symbol
      end
    end
    
    def remove_tag(symbol)
      @tag_mutex.synchronize do
        @tags.reject! { |tag| tag == symbol }
      end
    end
    
    def tagged_with?(symbol)
      @tag_mutex.synchronize do
        @tags.include? symbol
      end
    end

    def deliver_message(message)
      inbox << message
    end
    alias << deliver_message

    def inbox
      @inbox ||= Queue.new
    end

    def hangup!
      io.close
      Adhearsion.remove_inactive_call self
    end

    def closed?
      io.closed?
    end
    
    # Asterisk sometimes uses the "failed" extension to indicate a failed dial attempt.
    # Since it may be important to handle these, this flag helps the dialplan Manager
    # figure that out.
    def failed_call?
      @failed_call
    end
    
    def hungup_call?
      @hungup_call
    end
    
    # Adhearsion indexes calls by this identifier so they may later be found and manipulated. For calls from Asterisk, this
    # method uses the following properties for uniqueness, falling back to the next if one is for some reason unavailable:
    #
    #     Asterisk channel ID     ->        unique ID        -> Call#object_id
    # (e.g. SIP/mytrunk-jb12c88a) -> (e.g. 1215039989.47033) -> (e.g. 2792080)
    #
    # Note: channel is used over unique ID because channel may be used to bridge two channels together.
    def unique_identifier
      case originating_voip_platform
        when :asterisk
          variables[:channel] || variables[:uniqueid] || object_id
        when :callweaver
          variables[:channel] || variables[:uniqueid] || object_id
        else
          raise NotImplementedError
      end
    end
    
    def define_variable_accessors(recipient=self)
      variables.each do |key, value| 
        define_singleton_accessor_with_pair(key, value, recipient)
      end
    end
    
    def extract_failed_reason_from(environment)
      if originating_voip_platform == :asterisk || originating_voip_platform == :callweaver
        failed_reason = environment.variable 'REASON'
        failed_reason &&= ASTERISK_FRAME_STATES[failed_reason.to_i]
        define_singleton_accessor_with_pair(:failed_reason, failed_reason, environment)
      end
    end
    
    private
      
      def define_singleton_accessor_with_pair(key, value, recipient=self)
        recipient.metaclass.send :attr_accessor, key unless recipient.class.respond_to?("#{key}=")
        recipient.send "#{key}=", value
      end
      
      def check_if_valid_call
        extension = variables[:extension]
        @failed_call = true if extension == 'failed'
        @hungup_call = true if extension == 'h'
        raise UselessCallException if extension == 't' # TODO: Move this whole method to Manager
      end
    
      def set_originating_voip_platform! platform=:asterisk
        # TODO: we can make this determination programatically at some point,
        # but it will probably involve a bit more engineering than just a case statement (like
        # subclasses of Call for the various platforms), so we'll be totally cheap for now.
        self.originating_voip_platform = platform
      end
    
    module Variables
      
      module Coercions

        COERCION_ORDER = %w{
          remove_agi_prefixes_from_keys_and_strip_whitespace
          remove_ogi_prefixes_from_keys_and_strip_whitespace
          coerce_keys_into_symbols
          coerce_extension_into_phone_number_object
          coerce_numerical_values_to_numerics
          replace_unknown_values_with_nil
          replace_yes_no_answers_with_booleans
          coerce_request_into_uri_object
          decompose_uri_query_into_hash
          override_variables_with_query_params
          remove_dashes_from_context_name
          coerce_type_of_number_into_symbol
        }

        class << self
          
          def remove_agi_prefixes_from_keys_and_strip_whitespace(variables)
            variables.inject({}) do |new_variables,(key,value)|
              returning new_variables do
                stripped_name = key.kind_of?(String) ? key[/^(agi_)?(.+)$/,2] : key
                new_variables[stripped_name] = value.kind_of?(String) ? value.strip : value
              end
            end
          end

	 def remove_ogi_prefixes_from_keys_and_strip_whitespace(variables)
            variables.inject({}) do |new_variables,(key,value)|
              returning new_variables do
                stripped_name = key.kind_of?(String) ? key[/^(ogi_)?(.+)$/,2] : key
                new_variables[stripped_name] = value.kind_of?(String) ? value.strip : value
              end
            end
          end
          
          def coerce_keys_into_symbols(variables)
            variables.inject({}) do |new_variables,(key,value)|
              returning new_variables do
                new_variables[key.to_sym] = value
              end
            end
          end
          
          def coerce_extension_into_phone_number_object(variables)
            returning variables do
              variables[:extension] = Adhearsion::VoIP::DSL::PhoneNumber.new(variables[:extension])
            end
          end
          
          def coerce_numerical_values_to_numerics(variables)
            variables.inject({}) do |vars,(key,value)|
              returning vars do
                is_numeric = value =~ /^-?\d+(?:(\.)\d+)?$/
                is_float   = $1
                vars[key] = if is_numeric
                  if Adhearsion::VoIP::DSL::NumericalString.starts_with_leading_zero?(value)
                    Adhearsion::VoIP::DSL::NumericalString.new(value)
                  else
                    if is_float
                      if key == :uniqueid
                        value
                      else
                        value.to_f
                      end
                    else
                      value.to_i
                    end
                  end
                else
                  value
                end
              end
            end
          end

          def replace_unknown_values_with_nil(variables)
            variables.each do |key,value|
              variables[key] = nil if value == 'unknown'
            end
          end

          def replace_yes_no_answers_with_booleans(variables)
            variables.each do |key,value|
              case value
                when 'yes' : variables[key] = true
                when 'no'  : variables[key] = false
              end
            end
          end
          
          def coerce_request_into_uri_object(variables)
            if variables[:request]
              variables[:request] = URI.parse(variables[:request]) unless variables[:request].kind_of? URI
            end
            variables
          end
          
          def coerce_type_of_number_into_symbol(variables)
            returning variables do
              variables[:type_of_calling_number] = Adhearsion::VoIP::Constants::Q931_TYPE_OF_NUMBER[variables.delete(:callington).to_i]
            end
          end

          def decompose_uri_query_into_hash(variables)
            returning variables do
              if variables[:request] && variables[:request].query
                variables[:query] = variables[:request].query.split('&').inject({}) do |query_string_parameters, key_value_pair|
                  parameter_name, parameter_value = *key_value_pair.match(/(.+)=(.*)/).captures
                  query_string_parameters[parameter_name] = parameter_value
                  query_string_parameters
                end
              else
                variables[:query] = {}
              end
            end
          end
          
          def override_variables_with_query_params(variables)
            returning variables do
              if variables[:query]
                variables[:query].each do |key, value|
                  variables[key.to_sym] = value
                end
              end
            end
          end
          
          def remove_dashes_from_context_name(variables)
            returning variables do
              variables[:context].gsub!('-', '_')
            end
          end
          
        end
      end

      class Parser
        
        class << self
          def parse(*args, &block)
            returning new(*args, &block) do |parser|
              parser.parse
            end
          end
          
          def coerce_variables(variables)
            Coercions::COERCION_ORDER.inject(variables) do |tmp_variables, coercing_method_name|
              Coercions.send(coercing_method_name, tmp_variables)
            end
          end
          
          def separate_line_into_key_value_pair(line)
            line.match(/^([^:]+):\s?(.+)/).captures
          end
        end
      
        attr_reader :io, :variables, :lines
        def initialize(io)
          @io = io
          @lines = []
        end
      
        def parse
          extract_variable_lines_from_io
          initialize_variables_as_hash_from_lines
          @variables = self.class.coerce_variables(variables)
        end
        
        private
          
          def initialize_variables_as_hash_from_lines
            @variables = lines.inject({}) do |new_variables,line|
              returning new_variables do
                key, value = self.class.separate_line_into_key_value_pair line
                new_variables[key] = value
              end
            end
          end
          
          def extract_variable_lines_from_io
            while line = io.readline.chomp
            p line
              break if line.empty?
              @lines << line
            end
          end
        
      end
    
    end
  end  
end
