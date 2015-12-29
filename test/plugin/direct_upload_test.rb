require "test_helper"
require "shrine/storage/s3"
require "rack/test_app"

describe "the direct_upload plugin" do
  def app
    Rack::TestApp.wrap(@uploader.class::UploadEndpoint)
  end

  before do
    @uploader = uploader(:cache) { plugin :direct_upload }
  end

  describe "POST /:storage/:name" do
    before do
      skip "https://github.com/rubinius/rubinius/issues/3544" if RUBY_ENGINE == "rbx"
    end

    it "returns a JSON response" do
      response = app.post "/cache/avatar", multipart: {file: image}

      assert_equal 200, response.status
      assert_equal "application/json", response.headers["Content-Type"]
    end

    it "uploads the given file" do
      response = app.post "/cache/avatar", multipart: {file: image}

      assert @uploader.storage.exists?(response.body_json["id"])
    end

    it "passes in :name and :phase parameters as context" do
      @uploader.class.class_eval do
        def generate_location(io, context)
          context.to_json
        end
      end

      response = app.post "/cache/avatar", multipart: {file: image}

      assert_equal '{"name":"avatar","phase":"cache"}', response.body_json['id']
    end

    it "assigns metadata" do
      response = app.post "/cache/avatar", multipart: {file: image}

      metadata = response.body_json.fetch('metadata')
      assert_equal 'image.jpg', metadata['filename']
      assert_equal 'image/jpeg', metadata['mime_type']
      assert_kind_of Integer, metadata['size']
    end

    it "serializes uploaded hashes and arrays as well" do
      uploaded_file = @uploader.upload(fakeio)

      @uploader.class.class_eval { define_method(:upload) { |*| Hash[thumb: uploaded_file] } }
      response = app.post "/cache/avatar", multipart: {file: image}
      refute_empty response.body_json.fetch('thumb')

      @uploader.class.class_eval { define_method(:upload) { |*| Array[uploaded_file] } }
      response = app.post "/cache/avatar", multipart: {file: image}
      refute_empty response.body_json.fetch(0)
    end

    it "refuses files which are too big" do
      @uploader.opts[:direct_upload_max_size] = 0
      response = app.post "/cache/avatar", multipart: {file: image}
      assert_http_error 413, response

      @uploader.opts[:direct_upload_max_size] = 5 * 1024 * 1024
      response = app.post "/cache/avatar", multipart: {file: image}
      assert_equal 200, response.status
    end

    it "accepts only POST requests" do
      response = app.put "/cache/avatar", multipart: {file: image}

      assert_equal 404, response.status
    end

    it "returns appropriate error message for missing file" do
      response = app.post "/cache/avatar"

      assert_http_error 400, response
    end

    it "returns appropriate error message for invalid file" do
      response = app.post "/cache/avatar", query: {file: "foo"}

      assert_http_error 400, response
    end

    it "allows other errors to propagate" do
      @uploader.class.class_eval do
        def process(io, context)
          raise
        end
      end

      assert_raises(RuntimeError) { app.post "/cache/avatar", multipart: {file: image} }
    end

    it "doesn't exist if :presign was set" do
      @uploader.opts[:direct_upload_presign] = true
      response = app.post "/cache/avatar"

      assert_equal 404, response.status
    end
  end

  describe "GET /:storage/presign" do
    before do
      @uploader.class.storages[:cache] = Shrine::Storage::S3.new(
        bucket:            "foo",
        region:            "eu-west-1",
        access_key_id:     "abc123",
        secret_access_key: "xyz123",
      )
      @uploader.opts[:direct_upload_presign] = true
    end

    it "returns a presign object" do
      response = app.get "/cache/presign"

      refute_empty response.body_json.fetch("url")
      refute_empty response.body_json.fetch("fields")
    end

    it "accepts an extension" do
      response = app.get "/cache/presign?extension=.jpg"

      assert_match /\.jpg$/, response.body_json["fields"].fetch("key")
    end

    it "applies options passed to configuration" do
      @uploader.opts[:direct_upload_presign] = ->(r) do
        {content_type: r.params["content_type"]}
      end
      response = app.get "/cache/presign?content_type=image/jpeg"

      assert_equal "image/jpeg", response.body_json["fields"].fetch("Content-Type")
    end

    it "allows the configuration block to return nil" do
      @uploader.opts[:direct_upload_presign] = ->(r) { nil }
      response = app.get "/cache/presign"

      assert_equal 200, response.status
    end

    it "doesn't exist if :presign wasn't set" do
      @uploader.opts[:direct_upload_presign] = false
      response = app.get "cache/presign"

      assert_equal 404, response.status
    end
  end

  it "refuses storages which are not allowed" do
    response = app.post "/store/avatar"

    assert_http_error 403, response
  end

  it "refuses storages which are nonexistent" do
    response = app.post "/nonexistent/avatar"

    assert_http_error 403, response
  end

  it "makes the endpoint inheritable" do
    endpoint1 = Class.new(@uploader.class)::UploadEndpoint
    endpoint2 = Class.new(@uploader.class)::UploadEndpoint

    refute_equal endpoint1, endpoint2
  end

  def assert_http_error(status, response)
    assert_equal status, response.status
    assert_equal "application/json", response.headers["Content-Type"]
    refute_empty response.body_json.fetch("error")
  end
end
