# frozen_string_literal: true

require 'aspera/rest'
require 'aspera/aoc'

module Aspera
  module Cli
    module Plugins
      class Alee < BasicAuthPlugin
        ACTIONS = %i[entitlement].freeze

        def execute_action
          command = options.get_next_command(ACTIONS)
          case command
          when :entitlement
            entitlement_id = options.get_option(:username,is_type: :mandatory)
            customer_id = options.get_option(:password,is_type: :mandatory)
            api_metering = AoC.metering_api(entitlement_id,customer_id)
            return {type: :single_object, data: api_metering.read('entitlement')[:data]}
          end
        end
      end # Aspera
    end # Plugins
  end # Cli
end # Aspera
