# frozen_string_literal: true

class Audit < ApplicationRecord
  self.table_name = 'audits'

  belongs_to :user, foreign_key: :user_id, primary_key: :user_id, optional: true

  def as_json(options = {})
    super(options.merge(
      methods: %i[changes last_login],
      include: {
        user: {
          methods: %i[name]
        }
      },
      except: %i[audited_changes]
    ))
  end

  def changes
    permitted_classes = [Date, Time]
    json = Psych.safe_load(audited_changes || '{}', permitted_classes: permitted_classes, aliases: true)
    return [] if json.blank?

    case action
    when 'update'
      json.map { |key, value| { key => { previous: value[0], current: value[1] } } }
    when 'create'
      json.map { |key, value| { key => { previous: nil, current: value } } }
    when 'destroy'
      json.map { |key, value| { key => { previous: value, current: nil } } }
    else
      []
    end
  end

  def last_login
    user&.date_changed
  end
end
