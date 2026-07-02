# frozen_string_literal: true

module MahisUserImport
  class UsernameGenerator
    def self.generate(value)
      I18n.transliterate(value.to_s)
          .strip
          .downcase
          .gsub(/\s+/, '')
          .presence
    end
  end
end
