# frozen_string_literal: true

module Qes
  module Extensions
    module Lib
      module CreateFromSubmitters
        def merge_submitters_and_fields(submitter_attrs, template_submitters, template_fields)
          super(submitter_attrs, template_submitters, template_fields.deep_dup)
        end

        def assign_field_attrs(field, attrs)
          result = super
          field['required'] = true if field['type'] == 'qes' && attrs.key?('required')
          result
        end
      end
    end
  end
end
