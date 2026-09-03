module Certificates
  # Canonical JSON, so a digest is a function of the DATA and not of the order a
  # Ruby hash happened to be built in.
  #
  # Without this, adding a field to the payload builder - or a Ruby version
  # changing hash iteration - would silently invalidate every certificate ever
  # issued. Keys are sorted recursively at every depth, and the output has no
  # optional whitespace.
  module Canonical
    def self.dump(value)
      JSON.generate(normalize(value))
    end

    def self.digest(value)
      Digest::SHA256.hexdigest(dump(value))
    end

    def self.normalize(value)
      case value
      when Hash
        # Stringify first, then sort. Reaching for value[key] || value[key.to_sym]
        # would turn a legitimate `false` into nil - and "consent checkbox was
        # ticked: false" becoming "not recorded" is exactly the kind of silent
        # corruption a signed document must not have.
        stringified = value.each_with_object({}) { |(key, inner), memo| memo[key.to_s] = normalize(inner) }
        stringified.keys.sort.index_with { |key| stringified[key] }
      when Array
        value.map { |element| normalize(element) }
      when Time, DateTime
        value.utc.iso8601(3)
      when Date
        value.iso8601
      when Float
        # Round-trip stability: 0.1 + 0.2 must not produce a different digest on
        # a different platform.
        value.round(6)
      when Symbol
        value.to_s
      else
        value
      end
    end
  end
end
