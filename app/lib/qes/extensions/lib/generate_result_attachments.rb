# frozen_string_literal: true

module Qes
  module Extensions
    module Lib
      module GenerateResultAttachments
        def call(submitter)
          return super unless Qes.active_for?(submitter.submission)

          Qes::ResultAttachments.call(submitter)
        end
      end
    end
  end
end
