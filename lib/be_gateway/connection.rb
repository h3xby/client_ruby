module BeGateway
  module Connection
    MAX_RETRY_COUNT = 3

    extend ActiveSupport::Concern
    extend Forwardable
    def_delegators :connection, :headers, :headers=

    attr_reader :opts

    included do
      cattr_accessor :rack_app, :stub_app, :proxy
    end

    def initialize(params)
      @login = params.fetch(:shop_id)
      @password = params.fetch(:secret_key)
      @url = params.fetch(:url)
      @logger = params[:logger]
      @opts = params[:options] || {}
    end

    private

    attr_reader :login, :password, :url

    def send_request(method, path, params = nil)
      retry_count = MAX_RETRY_COUNT
      uuid = SecureRandom.uuid

      r = begin
            connection.public_send(method, path, params) do |req|
              req.headers["RequestID"] = uuid
            end
          rescue Faraday::Error::ClientError
            retry_count -= 1
            retry if retry_count > 0

            OpenStruct.new(
              status: 500,
              body: {
                'response' => {
                  'message' => 'Gateway is temporarily unavailable',
                  'errors' => {
                    'gateway' => 'is temporarily unavailable'
                  }
                }
              }
            )
          end
      (200..299).cover?(r.status) ? Response.new(r.body) : ErrorResponse.new(r.body)
    end

    def connection
      @connection ||= Faraday::Connection.new(url, opts || {}) do |conn|
        conn.options[:open_timeout] = 15
        conn.options[:timeout] = 30
        conn.options[:proxy] = proxy if proxy
        conn.request :json
        conn.request :basic_auth, login, password
        conn.response :json
        conn.response :logger, logger
        if stub_app
          conn.adapter :test, stub_app
        elsif rack_app
          conn.adapter :rack, rack_app.new
        else
          conn.adapter Faraday.default_adapter
        end
      end
    end

    def logger
      @logger ||= Logger.new(STDOUT).tap { |l| l.level = Logger::INFO }
    end
  end
end
