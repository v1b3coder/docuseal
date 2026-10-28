# frozen_string_literal: true

module Qes
  # Instalace rozšíření do upstream tříd. Jen nové chování (validace, callbacky,
  # asociace, rescue_from) nebo `super` wrapper; nikdy náhrada těla metody.
  module Extensions
    module_function

    def install!
      install(Template, Models::Template)
      install(Submission, Models::Submission)
      install(Submitter, Models::Submitter)
      install_singleton(Submitters::SubmitValues, Lib::SubmitValues)
      install_singleton(Submissions::CreateFromSubmitters, Lib::CreateFromSubmitters)
      install_singleton(Submissions::GenerateCombinedAttachment, Lib::GenerateCombinedAttachment)
      install_singleton(Submissions::GenerateResultAttachments, Lib::GenerateResultAttachments)
      install_singleton(VerifyPdfSignature, Lib::VerifyPdfSignature)
      install(TemplatesController, Controllers::TemplateErrors)
      install(Api::TemplatesController, Controllers::TemplateErrors)
      install(TemplatesPreferencesController, Controllers::TemplateErrors)
    end

    def install(target, mod)
      target.prepend(mod) unless target.ancestors.include?(mod)
    end

    def install_singleton(target, mod)
      target.singleton_class.prepend(mod) unless target.singleton_class.ancestors.include?(mod)
    end
  end
end
