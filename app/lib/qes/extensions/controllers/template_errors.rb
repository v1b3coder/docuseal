# frozen_string_literal: true

module Qes
  module Extensions
    module Controllers
      # 422 s textem pro QES validace šablony; pro non-QES nechá upstream 500.
      module TemplateErrors
        extend ActiveSupport::Concern

        QES_ERROR_PREFIX = 'qes_'

        prepended do
          rescue_from ActiveRecord::RecordInvalid, with: :render_qes_template_error
        end

        private

        def render_qes_template_error(error)
          record = error.record

          # Jiný záznam nebo jiná validace = upstream chování (500), ne QES 422.
          raise error unless Qes.enabled? && qes_template_error?(record)

          message = record.errors.map do |item|
            I18n.t("qes.error.#{item.message}", default: item.full_message)
          end.to_sentence

          if request.format.json?
            render json: { error: message }, status: :unprocessable_content
          else
            flash.now[:alert] = message
            render :show, layout: 'plain', status: :unprocessable_content
          end
        end

        def qes_template_error?(record)
          record.is_a?(Template) &&
            record.errors.present? &&
            record.errors.all? { |item| item.message.to_s.start_with?(QES_ERROR_PREFIX) }
        end
      end
    end
  end
end
