# frozen-string-literal: true

require "down/version"
require "down/chunked_io"
require "down/errors"
require "down/utils"

require "fileutils"
require "addressable/uri"

module Down
  class Backend
    def self.download(*args, &block)
      new.download(*args, &block)
    end

    def self.open(*args, &block)
      new.open(*args, &block)
    end

    private

    def normalize(url)
      uri = Addressable::URI.parse(url).normalize
      raise if uri.host.nil?
      uri.to_s
    rescue
      raise Down::InvalidUrl
    end

    # If destination path is defined, move tempfile to the destination,
    # otherwise return the tempfile unchanged.
    def download_result(tempfile, destination)
      return tempfile unless destination

      tempfile.close # required for Windows
      FileUtils.mv tempfile.path, destination

      nil
    end
  end
end
