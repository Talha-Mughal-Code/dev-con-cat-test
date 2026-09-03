module Engine
  # What one evaluator returns: the findings, a human summary, and the vendor
  # detail worth retaining as evidence on the certificate.
  Assessment = Struct.new(:module_key, :findings, :summary, :breakdown, keyword_init: true) do
    def initialize(*)
      super
      self.findings ||= []
      self.breakdown ||= {}
    end

    def clean? = findings.empty?
  end
end
