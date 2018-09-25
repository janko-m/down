# frozen-string-literal: true

require "open-uri"
require "net/https"

require "down/backend"

require "tempfile"
require "fileutils"

module Down
  # Provides streaming downloads implemented with Net::HTTP and open-uri.
  class NetHttp < Backend
    # Initializes the backend with common defaults.
    def initialize(options = {})
      @options = {
        "User-Agent" => "Down/#{Down::VERSION}",
        max_redirects: 2,
        open_timeout:  30,
        read_timeout:  30,
      }.merge(options)
    end

    # Downloads a remote file to disk using open-uri. Accepts any open-uri
    # options, and a few more.
    def download(url, options = {})
      options = @options.merge(options)

      max_size            = options.delete(:max_size)
      max_redirects       = options.delete(:max_redirects)
      progress_proc       = options.delete(:progress_proc)
      content_length_proc = options.delete(:content_length_proc)
      destination         = options.delete(:destination)

      # Use open-uri's :content_lenth_proc or :progress_proc to raise an
      # exception early if the file is too large.
      #
      # Also disable following redirects, as we'll provide our own
      # implementation that has the ability to limit the number of redirects.
      open_uri_options = {
        content_length_proc: proc { |size|
          if size && max_size && size > max_size
            raise Down::TooLarge, "file is too large (max is #{max_size/1024/1024}MB)"
          end
          content_length_proc.call(size) if content_length_proc
        },
        progress_proc: proc { |current_size|
          if max_size && current_size > max_size
            raise Down::TooLarge, "file is too large (max is #{max_size/1024/1024}MB)"
          end
          progress_proc.call(current_size) if progress_proc
        },
        redirect: false,
      }

      # Handle basic authentication in the :proxy option.
      if options[:proxy]
        proxy    = URI(options.delete(:proxy))
        user     = proxy.user
        password = proxy.password

        if user || password
          proxy.user     = nil
          proxy.password = nil

          open_uri_options[:proxy_http_basic_authentication] = [proxy.to_s, user, password]
        else
          open_uri_options[:proxy] = proxy.to_s
        end
      end

      open_uri_options.merge!(options)

      uri = ensure_uri(url)

      # Handle basic authentication in the remote URL.
      if uri.user || uri.password
        open_uri_options[:http_basic_authentication] ||= [uri.user, uri.password]
        uri.user = nil
        uri.password = nil
      end

      open_uri_file = open_uri(uri, open_uri_options, follows_remaining: max_redirects)

      # Handle the fact that open-uri returns StringIOs for small files.
      tempfile = ensure_tempfile(open_uri_file, File.extname(open_uri_file.base_uri.path))
      OpenURI::Meta.init tempfile, open_uri_file # add back open-uri methods
      tempfile.extend Down::NetHttp::DownloadedFile

      download_result(tempfile, destination)
    end

    # Starts retrieving the remote file using Net::HTTP and returns an IO-like
    # object which downloads the response body on-demand.
    def open(url, options = {})
      options = @options.merge(options)

      uri = ensure_uri(url)

      # Create a Fiber that halts when response headers are received.
      request = Fiber.new do
        net_http_request(uri, options) do |response|
          Fiber.yield response
        end
      end

      response = request.resume

      response_error!(response) unless response.is_a?(Net::HTTPSuccess)

      # Build an IO-like object that will retrieve response body on-demand.
      Down::ChunkedIO.new(
        chunks:     enum_for(:stream_body, response),
        size:       response["Content-Length"] && response["Content-Length"].to_i,
        encoding:   response.type_params["charset"],
        rewindable: options.fetch(:rewindable, true),
        on_close:   -> { request.resume }, # close HTTP connnection
        data: {
          status:   response.code.to_i,
          headers:  response.each_header.inject({}) { |headers, (downcased_name, value)|
                      name = downcased_name.split("-").map(&:capitalize).join("-")
                      headers.merge!(name => value)
                    },
          response: response,
        },
      )
    end

    private

    # Calls open-uri's URI::HTTP#open method. Additionally handles redirects.
    def open_uri(uri, options, follows_remaining: 0)
      uri.open(options)
    rescue OpenURI::HTTPRedirect => exception
      raise Down::TooManyRedirects, "too many redirects" if follows_remaining == 0

      # fail if redirect URI scheme is not http or https
      begin
        uri = ensure_uri(exception.uri)
      rescue Down::InvalidUrl
        response = rebuild_response_from_open_uri_exception(exception)

        raise ResponseError.new("Invalid Redirect URI: #{exception.uri}", response: response)
      end

      # forward cookies on the redirect
      if !exception.io.meta["set-cookie"].to_s.empty?
        options["Cookie"] = exception.io.meta["set-cookie"]
      end

      follows_remaining -= 1
      retry
    rescue OpenURI::HTTPError => exception
      response = rebuild_response_from_open_uri_exception(exception)

      # open-uri attempts to parse the redirect URI, so we re-raise that exception
      if exception.message.include?("(Invalid Location URI)")
        raise ResponseError.new("Invalid Redirect URI: #{response["Location"]}", response: response)
      end

      response_error!(response)
    rescue => exception
      request_error!(exception)
    end

    # Converts the given IO into a Tempfile if it isn't one already (open-uri
    # returns a StringIO when there is less than 10KB of content), and gives
    # it the specified file extension.
    def ensure_tempfile(io, extension)
      tempfile = Tempfile.new(["down-net_http", extension], binmode: true)

      if io.is_a?(Tempfile)
        # Windows requires file descriptors to be closed before files are moved
        io.close
        tempfile.close
        FileUtils.mv io.path, tempfile.path
      else
        IO.copy_stream(io, tempfile)
        io.close
      end

      tempfile.open
      tempfile
    end

    # Makes a Net::HTTP request and follows redirects.
    def net_http_request(uri, options, follows_remaining: options.fetch(:max_redirects, 2), &block)
      http, request = create_net_http(uri, options)

      begin
        response = http.start do
          http.request(request) do |response|
            unless response.is_a?(Net::HTTPRedirection)
              yield response
              # In certain cases the caller wants to download only one portion
              # of the file and close the connection, so we tell Net::HTTP that
              # it shouldn't continue retrieving it.
              response.instance_variable_set("@read", true)
            end
          end
        end
      rescue => exception
        request_error!(exception)
      end

      if response.is_a?(Net::HTTPRedirection)
        raise Down::TooManyRedirects if follows_remaining == 0

        # fail if redirect URI is not a valid http or https URL
        begin
          location = ensure_uri(response["Location"], allow_relative: true, is_redirect: true)
        rescue Down::InvalidUrl
          raise ResponseError.new("Invalid Redirect URI: #{response["Location"]}", response: response)
        end

        # handle relative redirects
        location = uri + location if location.relative?

        net_http_request(location, options, follows_remaining: follows_remaining - 1, &block)
      end
    end

    # Build a Net::HTTP object for making a request.
    def create_net_http(uri, options)
      http_class = Net::HTTP

      if options[:proxy]
        proxy = URI(options[:proxy])
        http_class = Net::HTTP::Proxy(proxy.hostname, proxy.port, proxy.user, proxy.password)
      end

      http = http_class.new(uri.host, uri.port)

      # Handle SSL parameters (taken from the open-uri implementation).
      if uri.is_a?(URI::HTTPS)
        http.use_ssl = true
        http.verify_mode = options[:ssl_verify_mode] || OpenSSL::SSL::VERIFY_PEER
        store = OpenSSL::X509::Store.new
        if options[:ssl_ca_cert]
          Array(options[:ssl_ca_cert]).each do |cert|
            File.directory?(cert) ? store.add_path(cert) : store.add_file(cert)
          end
        else
          store.set_default_paths
        end
        http.cert_store = store
      end

      http.read_timeout = options[:read_timeout] if options.key?(:read_timeout)
      http.open_timeout = options[:open_timeout] if options.key?(:open_timeout)

      request_headers = options.select { |key, value| key.is_a?(String) }
      request_headers["Accept-Encoding"] = "" # Net::HTTP's inflater causes FiberErrors

      get = Net::HTTP::Get.new(uri.request_uri, request_headers)
      get.basic_auth(uri.user, uri.password) if uri.user || uri.password

      [http, get]
    end

    # Yields chunks of the response body to the block.
    def stream_body(response, &block)
      response.read_body(&block)
    rescue => exception
      request_error!(exception)
    end

    # Checks that the url is a valid URI and that its scheme is http or https.
    def ensure_uri(url, allow_relative: false, is_redirect: false)
      begin
        url = normalize(url) unless is_redirect
        uri = URI(url)
      rescue URI::InvalidURIError => exception
        raise Down::InvalidUrl, exception.message
      end

      unless allow_relative && uri.relative?
        raise Down::InvalidUrl, "URL scheme needs to be http or https" unless uri.is_a?(URI::HTTP)
      end

      uri
    end

    # When open-uri raises an exception, it doesn't expose the response object.
    # Fortunately, the exception object holds response data that can be used to
    # rebuild the Net::HTTP response object.
    def rebuild_response_from_open_uri_exception(exception)
      code, message = exception.io.status

      response_class = Net::HTTPResponse::CODE_TO_OBJ.fetch(code)
      response       = response_class.new(nil, code, message)

      exception.io.metas.each do |name, values|
        values.each { |value| response.add_field(name, value) }
      end

      response
    end

    # Raises non-sucessful response as a Down::ResponseError.
    def response_error!(response)
      code    = response.code.to_i
      message = response.message.split(" ").map(&:capitalize).join(" ")

      args = ["#{code} #{message}", response: response]

      case response.code.to_i
      when 400..499 then raise Down::ClientError.new(*args)
      when 500..599 then raise Down::ServerError.new(*args)
      else               raise Down::ResponseError.new(*args)
      end
    end

    # Re-raise Net::HTTP exceptions as Down::Error exceptions.
    def request_error!(exception)
      case exception
      when Net::OpenTimeout
        raise Down::TimeoutError, "timed out waiting for connection to open"
      when Net::ReadTimeout
        raise Down::TimeoutError, "timed out while reading data"
      when EOFError, IOError, SocketError, SystemCallError
        raise Down::ConnectionError, exception.message
      when OpenSSL::SSL::SSLError
        raise Down::SSLError, exception.message
      else
        raise exception
      end
    end

    # Defines some additional attributes for the returned Tempfile (on top of what
    # OpenURI::Meta already defines).
    module DownloadedFile
      def original_filename
        Utils.filename_from_content_disposition(meta["content-disposition"]) ||
        Utils.filename_from_path(base_uri.path)
      end

      def content_type
        super unless meta["content-type"].to_s.empty?
      end
    end
  end
end
