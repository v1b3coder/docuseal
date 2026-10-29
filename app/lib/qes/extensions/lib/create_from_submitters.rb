# frozen_string_literal: true

module Qes
  module Extensions
    module Lib
      module CreateFromSubmitters
        def merge_submitters_and_fields(submitter_attrs, template_submitters, template_fields)
          super(submitter_attrs, template_submitters, template_fields.deep_dup)
        end

        def assign_field_attrs(field, attrs)
          # `required` QES pole je zmrazené ve snapshotu submissionu (N1);
          # API ho nesmí změnit ani na true, ani na false.
          snapshot_required = field['required']
          result = super
          field['required'] = snapshot_required if field['type'] == 'qes' && attrs.key?('required')
          result
        end
      end
    end
  end
end
