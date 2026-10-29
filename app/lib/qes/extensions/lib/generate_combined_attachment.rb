# frozen_string_literal: true

module Qes
  module Extensions
    module Lib
      module GenerateCombinedAttachment
        # Rozhoduje dokončená QES session, ne šablona (nález #3): volitelné
        # `qes` pole bez podpisu musí dostat upstream combined dokument.
        # `Qes.enabled?` zůstává feature gate — s vypnutým QES se QES kód nespouští.
        def call(submitter, with_audit: true)
          return super unless Qes.enabled? && submitter.qes_sessions.completed.exists?

          Qes::ResultAttachments.combined_document(submitter, with_audit:)
        end
      end
    end
  end
end
