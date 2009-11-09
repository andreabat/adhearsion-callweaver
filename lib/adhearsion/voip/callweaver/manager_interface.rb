require 'adhearsion/voip/asterisk'
module Adhearsion
  module VoIP
    module Callweaver
      
      ##
      # Sorry, this AMI class has been deprecated. Please see http://docs.adhearsion.com/Asterisk_Manager_Interface for
      # documentation on the new way of handling AMI. This new version is much better and should not require an enormous
      # migration on your part.
      #
      class AMI<Adhearsion::VoIP::Asterisk::AMI
      end
       mattr_accessor :manager_interface
       module Manager
        
        ##
        # This class abstracts a connection to the Asterisk Manager Interface. Its purpose is, first and foremost, to make
        # the protocol consistent. Though the classes employed to assist this class (ManagerInterfaceAction,
        # ManagerInterfaceResponse, ManagerInterfaceError, etc.) are relatively user-friendly, they're designed to be a
        # building block on which to build higher-level abstractions of the Asterisk Manager Interface.
        #
        # For a higher-level abstraction of the Asterisk Manager Interface, see the SuperManager class.
        #
        class ManagerInterface < Adhearsion::VoIP::Asterisk::Manager::ManagerInterface
        end  
        end
      
    end
  end
end
