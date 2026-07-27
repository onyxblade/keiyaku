# frozen_string_literal: true

RSpec.describe "a multipart/form-data body" do
  describe "a fully specified upload" do
    before do
      widgets.upload_photo(1, Widgets::UploadPhotoBody.new(
                                file: Keiyaku::Upload.new(StringIO.new("\x89PNG\r\n".b),
                                                          filename: "kaya.png",
                                                          content_type: "image/png"),
                                caption: "a dog", tags: %w[dog good]
                              ))
    end

    let(:request) { sent }
    let(:boundary) { request.content_type[/boundary=(.+)/, 1] }

    it "announces the boundary it used" do
      expect(request.content_type).to start_with "multipart/form-data; boundary=keiyaku-"
    end

    it "sends the file part with its filename and type" do
      expect(request.body).to include(%(Content-Disposition: form-data; name="file"; filename="kaya.png"))
      expect(request.body).to include("Content-Type: image/png")
    end

    it "sends the bytes untouched" do
      expect(request.body).to include("\x89PNG\r\n".b)
    end

    it "sends a scalar part with no type of its own" do
      expect(request.body).to include(%(name="caption"\r\n\r\na dog))
    end

    it "sends one part per element of an array property" do
      expect(request.body.scan(/name="tags"/).size).to eq 2
    end

    it "closes the body with the terminating boundary" do
      expect(request.body).to end_with "--#{boundary}--\r\n"
    end
  end

  describe "a bare IO" do
    before do
      File.open(document) { widgets.upload_photo(1, Widgets::UploadPhotoBody.new(file: _1)) }
    end

    let(:document) { File.expand_path("../examples/widgets.yaml", __dir__) }
    let(:request) { sent }

    it "is wrapped as a file part, taking its filename from the path" do
      expect(request.body).to include(%(filename="widgets.yaml"))
    end

    it "leaves out the properties that were nil" do
      expect(request.body.scan("Content-Disposition").size).to eq 1
    end
  end

  it "takes the body positionally, like any other" do
    expect(Widgets::Client.instance_method(:upload_photo).parameters).to eq [%i[req id], %i[req body]]
  end

  it "types a binary property as an upload only inside a multipart body" do
    expect(Widgets::UploadPhotoBody.types[:file]).to eq :upload
  end
end
