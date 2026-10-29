# frozen_string_literal: true

module Qes
  module Extensions
    module Lib
      module GenerateResultAttachments
        # Rozhoduje dokončená QES session, ne šablona (nález #3): volitelné
        # `qes` pole bez podpisu musí dostat upstream PDF, ne prázdný výsledek.
        def call(submitter)
          return super unless submitter.qes_sessions.completed.exists?

          Qes::ResultAttachments.call(submitter)
        end
      end
    end
  end
end
