module Docusign
  class TextTab < Tab
    def to_h
      super.merge(value: value)
    end
  end
end
