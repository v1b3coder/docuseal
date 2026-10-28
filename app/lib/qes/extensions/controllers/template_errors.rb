# frozen_string_literal: true

module Qes
  module Extensions
    module Controllers
      # 422 s textem pro QES validace šablony; pro non-QES nechá upstream 500.
      module TemplateErrors
        extend ActiveSupport::Concern

        prepended do
          rescue_from ActiveRecord::RecordInvalid, with: :render_qes_template_error
        end

        private

        def render_qes_template_error(error)
          raise error unless Qes.enabled? && @template&.fields&.any? { |field| field['type'] == 'qes' }

          message = @template.errors.map do |item|
            I18n.t("qes.error.#{item.message}", default: item.full_message)
          end.to_sentence

          if request.format.json?
            render json: { error: message }, status: :unprocessable_content
          else
            flash.now[:alert] = message
            render :show, layout: 'plain', status: :unprocessable_content
          end
        end
      end
    end
  end
end
