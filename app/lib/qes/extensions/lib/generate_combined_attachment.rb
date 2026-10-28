# frozen_string_literal: true

module Qes
  module Extensions
    module Lib
      module GenerateCombinedAttachment
        def call(submitter, with_audit: true)
          return super unless Qes.active_for?(submitter.submission)

          Qes::ResultAttachments.combined_document(submitter, with_audit:)
        end
      end
    end
  end
end
