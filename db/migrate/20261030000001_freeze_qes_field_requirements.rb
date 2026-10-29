# frozen_string_literal: true

# #16: rozběhnutá submission musí mít zmrazené požadavky QES polí. Starší
# submissions vznikly bez snapshotu (`template_fields` je `nil`), takže se `level`
# a `required` čtou z živé šablony a úprava šablony změní požadavek i uprostřed
# podpisu. Backfill zapíše snapshot z aktuální šablony; nové submissions ho už
# dostanou při vzniku (`Qes::Extensions::Models::Submission`).
class FreezeQesFieldRequirements < ActiveRecord::Migration[8.1]
  def up
    Submission.where(template_fields: [nil, '[]']).find_each do |submission|
      template = Template.find_by(id: submission.template_id)
      next if template.blank? || template.fields.none? { |field| field['type'] == 'qes' }

      submission.update_columns(template_fields: template.fields)
    end
  end

  def down
    # Snapshot se nedá vrátit: nevíme, které submissions ho neměly.
  end
end
