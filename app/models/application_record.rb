class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class

  # Small helper so JSON-in-text columns read like attributes without pulling in
  # a serialiser gem or committing to a Postgres jsonb column.
  def self.json_attribute(*names, default: {})
    names.each do |name|
      define_method(name) do
        raw = self[name]
        raw.blank? ? default.dup : (JSON.parse(raw) rescue default.dup)
      end

      define_method("#{name}=") do |value|
        self[name] = value.nil? ? nil : JSON.generate(value)
      end
    end
  end
end
