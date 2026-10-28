# frozen_string_literal: true

module Qes
  module Extensions
    module Lib
      module SubmitValues
        def update_submitter!(submitter, params, request, validate_required: true)
          submitter.with_lock { super }
        end

        def validate_values!(values, submitter, params, request)
          Qes::ValueValidator.call(values, submitter)
          super
        end
      end
    end
  end
end
